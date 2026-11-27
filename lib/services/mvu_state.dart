import 'dart:convert';

import '../models/character_card.dart';
import '../models/chat_message.dart';

/// 一个变量（只读展示用）。
class MvuValue {
  /// 扁平化后的名字，如 `stats.好感度`。
  final String name;
  final String value;

  const MvuValue(this.name, this.value);
}

/// 只读的变量 / 状态快照（v0.33.0）。
///
/// 说明：本 App **不执行** MVU / 卡内脚本，这里的值只是「从卡和聊天文本里
/// 读出来给你看」，不参与提示词，也不会写回对话。
class MvuSnapshot {
  final Map<String, String> values;
  final int updateCount;
  final int initCount;

  const MvuSnapshot({
    this.values = const {},
    this.updateCount = 0,
    this.initCount = 0,
  });

  static const MvuSnapshot empty = MvuSnapshot();

  bool get isEmpty => values.isEmpty;

  int get length => values.length;

  List<MvuValue> get entries =>
      values.entries.map((e) => MvuValue(e.key, e.value)).toList();

  /// 顶层分组名（`stats.好感度` → `stats`），没有前缀的返回空串。
  String? groupOf(MvuValue v) {
    final i = v.name.indexOf('.');
    return i <= 0 ? null : v.name.substring(0, i);
  }
}

/// 从卡扩展与聊天文本里「读」变量，全部是只读解析。
class MvuStateReader {
  /// 常见的状态更新块标签（不区分大小写）。
  static const List<String> blockTags = [
    'UpdateVariable',
    'UpdateVariableBlock',
    'JSONPatch',
  ];

  static const List<String> _initMarkers = ['[InitVar]', '【InitVar】'];

  /// 从角色卡读初始变量：`extensions.mvu` / `extensions.variables`，
  /// 以及开场白 / 系统提示里的 `[InitVar]{...}`。
  static MvuSnapshot fromCard(CharacterCard card) {
    final values = <String, String>{};
    var initCount = 0;

    final ext = card.extensions;
    final mvu = ext['mvu'];
    if (mvu is Map) {
      for (final key in const [
        'initialVariables',
        'initial_variables',
        'variables',
        'initvar',
        'state',
        'stats',
      ]) {
        final v = mvu[key];
        if (v is Map) {
          values.addAll(_flatten(v));
          initCount++;
        }
      }
      // mvu 直接就是变量表的情况
      final scalarLike = mvu.entries.where((e) => e.value is num || e.value is String || e.value is bool);
      if (scalarLike.isNotEmpty) {
        for (final e in scalarLike) {
          values.putIfAbsent('${e.key}', () => _format(e.value));
        }
        initCount++;
      }
    }
    final vars = ext['variables'];
    if (vars is Map) {
      values.addAll(_flatten(vars));
      initCount++;
    }

    for (final text in [card.firstMes, card.systemPrompt]) {
      final parsed = _initVarsIn(text);
      if (parsed.isNotEmpty) {
        values.addAll(parsed.map((k, v) => MapEntry(k, _format(v))));        initCount++;
      }
    }

    return MvuSnapshot(values: values, initCount: initCount);
  }

  /// 从聊天消息里累积状态更新（只读）。
  ///
  /// [base] 是卡内初始变量；返回的快照里 `updateCount` 表示找到了多少个更新块，
  /// 解析失败或没有更新块都不会抛异常。
  static MvuSnapshot fromMessages(
    List<ChatMessage> messages, {
    MvuSnapshot? base,
  }) {
    final state = <String, dynamic>{};
    if (base != null) state.addAll(base.values);
    var updates = 0;

    for (final m in messages) {
      for (final json in _blocksIn(m.content)) {
        updates++;
        if (json is List) {
          _applyPatch(state, json);
        } else if (json is Map) {
          state.addAll(json.map((k, v) => MapEntry('$k', v)));
        }
      }
      final init = _initVarsIn(m.content);
      if (init.isNotEmpty) state.addAll(init);
    }

    return MvuSnapshot(
      values: _flatten(state),
      updateCount: updates,
      initCount: base?.initCount ?? 0,
    );
  }

  /// 解析文本里的 `[InitVar]{...}`（可以有多个）。
  static Map<String, dynamic> _initVarsIn(String text) {
    final out = <String, dynamic>{};
    for (final marker in _initMarkers) {
      var from = 0;
      while (true) {
        final i = text.indexOf(marker, from);
        if (i < 0) break;
        final start = text.indexOf('{', i + marker.length);
        if (start < 0) break;
        final end = _braceEnd(text, start);
        if (end < 0) break;
        final raw = text.substring(start, end + 1);
        from = end + 1;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) out.addAll(decoded.map((k, v) => MapEntry('$k', v)));
        } catch (_) {
          // 坏 JSON 跳过
        }
      }
    }
    return out;
  }

  /// 找出内容里所有 `<Tag>...</Tag>` 并尝试解析 JSON。
  static List<dynamic> _blocksIn(String text) {
    final out = <dynamic>[];
    if (!text.contains('<')) return out;
    for (final tag in blockTags) {
      final lower = text.toLowerCase();
      final open = '<${tag.toLowerCase()}>';
      final close = '</${tag.toLowerCase()}>';
      var from = 0;
      while (true) {
        final i = lower.indexOf(open, from);
        if (i < 0) break;
        final j = lower.indexOf(close, i + open.length);
        final raw = j < 0
            ? text.substring(i + open.length)
            : text.substring(i + open.length, j);
        from = j < 0 ? text.length : j + close.length;
        try {
          out.add(jsonDecode(raw.trim()));
        } catch (_) {
          // 不是 JSON 就跳过
        }
        if (j < 0) break;
      }
    }
    return out;
  }

  static int _braceEnd(String text, int start) {
    var depth = 0;
    var inString = false;
    for (var i = start; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 应用 JSON Patch 子集：add / replace / remove，path 形如 `/stats/好感度`。
  static void _applyPatch(Map<String, dynamic> state, List<dynamic> ops) {
    for (final op in ops) {
      if (op is! Map) continue;
      final kind = '${op['op'] ?? ''}';
      final path = '${op['path'] ?? ''}';
      final keys = path.split('/').where((s) => s.isNotEmpty).toList();
      if (keys.isEmpty) continue;
      // 基础状态是「扁平点号」形式（如 stats.好感度），补丁路径优先按扁平键匹配，
      // 否则会额外建一层 stats，和已有键撞在一起。
      final flatKey = keys.join('.');
      if (state.containsKey(flatKey)) {
        if (kind == 'remove') {
          state.remove(flatKey);
        } else {
          state[flatKey] = op['value'];
        }
        continue;
      }
      if (keys.length == 1) {
        if (kind == 'remove') {
          state.remove(keys.first);
        } else {
          state[keys.first] = op['value'];
        }
        continue;
      }
      // 嵌套：只处理「中间是 Map」的情况，遇到非 Map 就重建一层
      Map<String, dynamic> cursor = state;
      for (var i = 0; i < keys.length - 1; i++) {
        final existing = cursor[keys[i]];
        if (existing is Map<String, dynamic>) {
          cursor = existing;
        } else {
          final created = <String, dynamic>{};
          cursor[keys[i]] = created;
          cursor = created;
        }
      }
      final last = keys.last;
      if (kind == 'remove') {
        cursor.remove(last);
      } else {
        cursor[last] = op['value'];
      }
    }
  }

  /// 把嵌套 Map 拍平成 `a.b = 值`。
  static Map<String, String> _flatten(Map<dynamic, dynamic> map, [String prefix = '']) {
    final out = <String, String>{};
    map.forEach((k, v) {
      final name = prefix.isEmpty ? '$k' : '$prefix.$k';
      if (v is Map) {
        out.addAll(_flatten(v, name));
      } else {
        out[name] = _format(v);
      }
    });
    return out;
  }

  static String _format(dynamic v) {
    if (v == null) return '空';
    if (v is String) return v;
    if (v is num || v is bool) return '$v';
    final text = jsonEncode(v);
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
