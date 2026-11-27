import 'dart:math';

import '../models/chat_message.dart';
import '../models/world_info.dart';
import 'hit_stats.dart';
import 'macros.dart';

/// 一条激活的世界词条目：宏替换后的内容 + 来源世界书名 +
/// 注入位置（0 system 最前 / 1 历史深度 / 2 角色设定后，供 PromptBuilder 分流）。
class ActivatedEntry {
  final String source;
  final String content;
  final int position;
  final int depth;

  /// 条目稳定标识（命中率统计 key，见 hit_stats.entryKeyOf）
  final String entryKey;

  /// 展示名：首关键词，空关键词时用内容预览
  final String label;

  const ActivatedEntry({
    required this.source,
    required this.content,
    this.position = 0,
    this.depth = 0,
    this.entryKey = '',
    this.label = '',
  });
}

/// 条目展示名：首关键词；无关键词时取内容前 16 字（压平换行）。
String entryLabelOf(WorldInfoEntry e) {
  final first = e.keys.isNotEmpty ? e.keys.first.trim() : '';
  if (first.isNotEmpty) return first;
  final flat = e.content.replaceAll('\n', ' ').trim();
  if (flat.isEmpty) return '未命名条目';
  return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
}

/// 命中测试用：单条条目的检查结果。
class EntryInspection {
  const EntryInspection({
    required this.entry,
    required this.source,
    required this.activated,
    required this.reason,
    required this.order,
  });

  final WorldInfoEntry entry;
  final String source;
  final bool activated;

  /// 给用户看的中文原因（已激活 / 未激活都说明为什么）
  final String reason;

  /// 书内顺序（并列时排序用）
  final int order;
}

/// 世界书关键词激活引擎。
///
/// 激活逻辑：
/// 1. 取最近 scanDepth 条消息的全部文本（小写化；scanDepth 0 = 全程）
/// 2. 条目任一 key（不区分大小写，contains 匹配）出现在文本中 → 初步命中
/// 3. keysecondary 非空时，还需至少一个 secondary key 命中（AND 语义）
/// 4. disabled 跳过；useProbability 为 true 时按百分比随机
/// 5. recursive 条目把已激活条目 content 并入匹配文本再跑一轮（最多迭代 3 层）
/// 6. 命中条目按 insertion_order 升序，宏替换后返回（带来源标注 + position/depth）
class WorldInfoEngine {
  /// [books] 为需要参与激活的世界书（卡内嵌 + 用户挂载的合并传入）。
  /// 返回按 insertion_order 升序的、已宏替换的条目（含来源世界书名）。
  static List<ActivatedEntry> activate({
    required List<WorldInfo> books,
    required List<ChatMessage> messages,
    required String charName,
    required String userName,
    Random? random,
  }) {
    final rnd = random ?? Random();

    // 合并所有条目，保留书内顺序做并列时的稳定排序
    final all = <(int, WorldInfoEntry, WorldInfo)>[];
    for (final book in books) {
      for (final e in book.entries) {
        if (e.disabled) continue;
        all.add((all.length, e, book));
      }
    }
    if (all.isEmpty) return [];

    // 每个 scanDepth 值对应的最近 N 条消息文本缓存；
    // scanDepth 0 = 全程（不截断），N>0 只回看最近 N 条
    final fullText =
        messages.map((m) => m.content.toLowerCase()).join('\n');
    final textCache = <int, String>{};
    String textFor(int depth) {
      if (depth <= 0) return fullText;
      return textCache.putIfAbsent(depth, () {
        final take = messages.length > depth
            ? messages.sublist(messages.length - depth)
            : messages;
        return take.map((m) => m.content.toLowerCase()).join('\n');
      });
    }

    bool matches(WorldInfoEntry e, String text) {
      // 无关键词的条目视为常驻条目（兼容 SillyTavern 行为）
      if (e.keys.isEmpty && e.keysSecondary.isEmpty) return true;
      if (e.keys.isEmpty) return false;
      var primaryHit = false;
      for (final k in e.keys) {
        if (k.isNotEmpty && text.contains(k.toLowerCase())) {
          primaryHit = true;
          break;
        }
      }
      if (!primaryHit) return false;
      if (e.keysSecondary.isNotEmpty) {
        var secondaryHit = false;
        for (final k in e.keysSecondary) {
          if (k.isNotEmpty && text.contains(k.toLowerCase())) {
            secondaryHit = true;
            break;
          }
        }
        if (!secondaryHit) return false;
      }
      return true;
    }

    bool roll(WorldInfoEntry e) {
      if (!e.useProbability) return true;
      final p = e.probability.clamp(0, 100);
      if (p >= 100) return true;
      if (p <= 0) return false;
      return rnd.nextInt(100) < p;
    }

    final activated = <(int, WorldInfoEntry, WorldInfo)>[];
    final activatedIdx = <int>{};

    // 第一轮：全部条目按自身 scanDepth 文本匹配
    for (final item in all) {
      final e = item.$2;
      if (matches(e, textFor(e.scanDepth)) && roll(e)) {
        activated.add(item);
        activatedIdx.add(item.$1);
      }
    }

    // 递归轮：把已激活条目 content 并入匹配文本，最多迭代 3 层
    for (var round = 0; round < 3; round++) {
      final extra = activated
          .map((t) =>
              applyMacros(t.$2.content, charName: charName, userName: userName)
                  .toLowerCase())
          .join('\n');
      var changed = false;
      for (final item in all) {
        final idx = item.$1;
        final e = item.$2;
        if (!e.recursive || activatedIdx.contains(idx)) continue;
        final text = '${textFor(e.scanDepth)}\n$extra';
        if (matches(e, text) && roll(e)) {
          activated.add(item);
          activatedIdx.add(idx);
          changed = true;
        }
      }
      if (!changed) break;
    }

    // 按 insertion_order 升序（用原始下标保证稳定）
    activated.sort((a, b) {
      final c = a.$2.insertionOrder.compareTo(b.$2.insertionOrder);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });

    return activated
        .map((t) => ActivatedEntry(
              source: t.$3.name.trim().isEmpty ? '未命名世界书' : t.$3.name.trim(),
              content:
                  applyMacros(t.$2.content, charName: charName, userName: userName),
              position: t.$2.position,
              depth: t.$2.depth,
              entryKey: entryKeyOf(t.$2),
              label: entryLabelOf(t.$2),
            ))
        .toList();
  }

  /// 命中测试（v0.27.0）：给出「这段文字会激活哪些条目、为什么」。
  ///
  /// 与 [activate] 用同一套匹配规则，但把每条都列出来并附原因，
  /// 方便在设置里解释「为什么没注入 / 为什么注入了」。
  static List<EntryInspection> inspect({
    required List<WorldInfo> books,
    required String text,
    required String charName,
    required String userName,
    Random? random,
  }) {
    final rnd = random ?? Random();
    final lower = text.toLowerCase();
    final all = <(int, WorldInfoEntry, WorldInfo)>[];
    for (final book in books) {
      for (final e in book.entries) {
        all.add((all.length, e, book));
      }
    }

    final reasons = <int, String>{};
    final ok = <int>{};

    for (final item in all) {
      final idx = item.$1;
      final e = item.$2;
      final check = _checkEntry(e, lower);
      if (check.ok) {
        if (e.useProbability && e.probability < 100) {
          final passed = e.probability > 0 && rnd.nextInt(100) < e.probability;
          if (!passed) {
            reasons[idx] = '关键词命中，但概率（${e.probability}%）这一次没通过';
            continue;
          }
        }
        ok.add(idx);
        reasons[idx] =
            '${check.reason}${_positionHint(e)}';
      } else {
        reasons[idx] = check.reason;
      }
    }

    // 递归轮：已激活条目的内容并入匹配文本，最多 3 层（与 activate 一致）
    for (var round = 0; round < 3; round++) {
      final extra = all
          .where((t) => ok.contains(t.$1) && t.$2.recursive)
          .map((t) =>
              applyMacros(t.$2.content, charName: charName, userName: userName)
                  .toLowerCase())
          .join('\n');
      var changed = false;
      for (final item in all) {
        final idx = item.$1;
        final e = item.$2;
        if (!e.recursive || ok.contains(idx) || e.disabled) continue;
        final check = _checkEntry(e, '$lower\n$extra');
        if (check.ok) {
          ok.add(idx);
          reasons[idx] = '递归命中：由其它已激活条目的内容触发${_positionHint(e)}';
          changed = true;
        }
      }
      if (!changed) break;
    }

    final out = <EntryInspection>[
      for (final item in all)
        EntryInspection(
          entry: item.$2,
          source: item.$3.name.trim().isEmpty ? '未命名世界书' : item.$3.name.trim(),
          activated: ok.contains(item.$1),
          reason: reasons[item.$1] ?? '未命中',
          order: item.$1,
        ),
    ];
    out.sort((a, b) {
      final c = a.entry.insertionOrder.compareTo(b.entry.insertionOrder);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return out;
  }

  /// 单条匹配；返回是否激活 + 原因（不含位置提示）。
  static ({bool ok, String reason}) _checkEntry(
    WorldInfoEntry e,
    String lowerText,
  ) {
    if (e.disabled) return (ok: false, reason: '已禁用，不会注入');
    if (e.keys.isEmpty && e.keysSecondary.isEmpty) {
      return (ok: true, reason: '常驻条目（没有关键词，总是注入）');
    }
    if (e.keys.isEmpty) {
      return (ok: false, reason: '只有次级关键词，缺少主关键词');
    }
    String? primary;
    for (final k in e.keys) {
      if (k.isNotEmpty && lowerText.contains(k.toLowerCase())) {
        primary = k;
        break;
      }
    }
    if (primary == null) {
      return (ok: false, reason: '关键词未命中：${e.keys.join('、')}');
    }
    if (e.keysSecondary.isNotEmpty) {
      var secondary = false;
      for (final k in e.keysSecondary) {
        if (k.isNotEmpty && lowerText.contains(k.toLowerCase())) {
          secondary = true;
          break;
        }
      }
      if (!secondary) {
        return (
          ok: false,
          reason: '主关键词「$primary」命中，但次级关键词未命中：'
              '${e.keysSecondary.join('、')}',
        );
      }
    }
    return (ok: true, reason: '关键词「$primary」命中');
  }

  static String _positionHint(WorldInfoEntry e) {
    if (e.position == 1) return '，按深度 ${e.depth} 注入对话';
    if (e.position == 2) return '，注入在角色设定之后';
    return '，注入在提示词开头';
  }
}
