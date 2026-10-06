import 'dart:math';

import '../models/chat_message.dart';
import '../models/world_info.dart';
import 'macros.dart';

/// 世界书关键词激活引擎。
///
/// 激活逻辑：
/// 1. 取最近 scanDepth 条消息的全部文本（小写化）
/// 2. 条目任一 key（不区分大小写，contains 匹配）出现在文本中 → 初步命中
/// 3. keysecondary 非空时，还需至少一个 secondary key 命中
/// 4. disabled 跳过；useProbability 为 true 时按百分比随机
/// 5. recursive 条目把已激活条目 content 并入匹配文本再跑一轮（最多迭代 3 层）
/// 6. 命中条目按 insertion_order 升序，宏替换后拼接返回
class WorldInfoEngine {
  /// [books] 为需要参与激活的世界书（卡内嵌 + 用户挂载的合并传入）。
  /// 返回按 insertion_order 升序的、已宏替换的内容列表。
  static List<String> activate({
    required List<WorldInfo> books,
    required List<ChatMessage> messages,
    required String charName,
    required String userName,
    Random? random,
  }) {
    final rnd = random ?? Random();

    // 合并所有条目，保留书内顺序做并列时的稳定排序
    final all = <(int, WorldInfoEntry)>[];
    for (final book in books) {
      for (final e in book.entries) {
        if (e.disabled) continue;
        all.add((all.length, e));
      }
    }
    if (all.isEmpty) return [];

    // 每个 scanDepth 值对应的最近 N 条消息文本缓存
    final textCache = <int, String>{};
    String textFor(int depth) {
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

    final activated = <(int, WorldInfoEntry)>[];
    final activatedIdx = <int>{};

    // 第一轮：全部条目按自身 scanDepth 文本匹配
    for (final (idx, e) in all) {
      if (matches(e, textFor(e.scanDepth)) && roll(e)) {
        activated.add((idx, e));
        activatedIdx.add(idx);
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
      for (final (idx, e) in all) {
        if (!e.recursive || activatedIdx.contains(idx)) continue;
        final text = '${textFor(e.scanDepth)}\n$extra';
        if (matches(e, text) && roll(e)) {
          activated.add((idx, e));
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
        .map((t) => applyMacros(t.$2.content,
            charName: charName, userName: userName))
        .toList();
  }
}
