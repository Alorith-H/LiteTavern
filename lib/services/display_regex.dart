import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'storage.dart';

/// 显示正则作用在谁身上（v0.29.0）。
enum RegexScope {
  all,
  user,
  assistant,
}

extension RegexScopeLabel on RegexScope {
  String get label => switch (this) {
        RegexScope.all => '全部消息',
        RegexScope.user => '只对你',
        RegexScope.assistant => '只对角色',
      };

  String get id => switch (this) {
        RegexScope.all => 'all',
        RegexScope.user => 'user',
        RegexScope.assistant => 'assistant',
      };

  static RegexScope fromId(Object? raw) => switch (raw) {
        'user' => RegexScope.user,
        'assistant' => RegexScope.assistant,
        _ => RegexScope.all,
      };
}

/// 一条显示正则：只改「看到的内容」，不改本地保存的原文（v0.29.0）。
///
/// 兼容 SillyTavern 正则导出格式：
/// `{ "scriptName": "...", "findRegex": "/pattern/flags", "replaceString": "...", "disabled": false }`
@immutable
class DisplayRegex {
  const DisplayRegex({
    required this.id,
    required this.name,
    required this.pattern,
    this.flags = '',
    this.replacement = '',
    this.enabled = true,
    this.scope = RegexScope.all,
  });

  final String id;
  final String name;

  /// 不含斜杠与 flags 的正则正文（SillyTavern 的 findRegex 会被拆开）。
  final String pattern;

  /// 标志位，允许的组合：i（忽略大小写）、m（多行）、s（. 匹配换行）、u（unicode）。
  final String flags;

  /// 替换文本，支持 `$1` / `${1}` / `$&`（整段命中）。
  final String replacement;

  final bool enabled;
  final RegexScope scope;

  bool get isDisabled => !enabled;

  /// 防护上限（v0.41.0）：避免超长 pattern（ReDoS 风险）或超长消息把 UI 卡死。
  static const int maxPatternLength = 1000;
  static const int maxAppliedLength = 200000;

  /// 正则写错时返回 null（界面上提示，不抛异常）。
  RegExp? compile() {
    if (pattern.length > maxPatternLength) return null;
    try {
      return RegExp(pattern, caseSensitive: !flags.contains('i'), multiLine: flags.contains('m'), dotAll: flags.contains('s'), unicode: flags.contains('u'));
    } catch (_) {
      return null;
    }
  }

  bool get hasError => compile() == null;

  bool matchesScope({required bool isUser}) => switch (scope) {
        RegexScope.all => true,
        RegexScope.user => isUser,
        RegexScope.assistant => !isUser,
      };

  /// 应用这条正则；正则非法、未启用或文本过长时原样返回。
  String apply(String text) {
    if (!enabled || text.isEmpty || text.length > maxAppliedLength) return text;
    final re = compile();
    if (re == null) return text;
    return text.replaceAllMapped(re, (m) => _expandReplacement(replacement, m));
  }

  DisplayRegex copyWith({
    String? name,
    String? pattern,
    String? flags,
    String? replacement,
    bool? enabled,
    RegexScope? scope,
  }) =>
      DisplayRegex(
        id: id,
        name: name ?? this.name,
        pattern: pattern ?? this.pattern,
        flags: flags ?? this.flags,
        replacement: replacement ?? this.replacement,
        enabled: enabled ?? this.enabled,
        scope: scope ?? this.scope,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'scriptName': name,
        // 统一写成 SillyTavern 能读回去的格式
        'findRegex': '/$pattern/$flags',
        'replaceString': replacement,
        'disabled': !enabled,
        'scope': scope.id,
      };

  static DisplayRegex fromSillyTavern(Object? raw, {String? fallbackId}) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final id = (map['id'] ?? fallbackId ?? _newId()).toString();
    final name = (map['scriptName'] ?? map['name'] ?? '未命名正则').toString();
    final (pattern, flags) = splitFindRegex((map['findRegex'] ?? '').toString());
    return DisplayRegex(
      id: id,
      name: name.trim().isEmpty ? '未命名正则' : name.trim(),
      pattern: pattern,
      flags: flags,
      replacement: (map['replaceString'] ?? map['replacement'] ?? '').toString(),
      enabled: map['disabled'] != true && map['enabled'] != false,
      scope: RegexScopeLabel.fromId(map['scope']),
    );
  }

  static String _newId() =>
      'rx_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 把 `/pattern/flags` 拆成正文与 flags；没有斜杠包裹时整段当正文。
  static (String, String) splitFindRegex(String raw) {
    final text = raw.trim();
    if (text.length < 2 || !text.startsWith('/')) return (text, '');
    final lastSlash = text.lastIndexOf('/');
    if (lastSlash <= 0) return (text, '');
    final body = text.substring(1, lastSlash);
    final flags = text.substring(lastSlash + 1).replaceAll(RegExp(r'[^imsu]'), '');
    return (body, flags);
  }

  /// `$1` / `${1}` / `$&` / `$$` 展开（Dart 的 replaceAll 不支持这些）。
  static String _expandReplacement(String replacement, Match match) {
    if (!replacement.contains(r'$')) return replacement;
    final out = StringBuffer();
    for (var i = 0; i < replacement.length; i++) {
      final ch = replacement[i];
      if (ch != r'$' || i == replacement.length - 1) {
        out.write(ch);
        continue;
      }
      final next = replacement[i + 1];
      if (next == r'$') {
        out.write(r'$');
        i++;
      } else if (next == '&') {
        out.write(match[0] ?? '');
        i++;
      } else if (next == '{') {
        final close = replacement.indexOf('}', i + 2);
        if (close == -1) {
          out.write(ch);
          continue;
        }
        final numText = replacement.substring(i + 2, close);
        out.write(_group(match, numText) ?? '');
        i = close;
      } else if (RegExp(r'\d').hasMatch(next)) {
        var j = i + 1;
        while (j < replacement.length && RegExp(r'\d').hasMatch(replacement[j])) {
          j++;
        }
        out.write(_group(match, replacement.substring(i + 1, j)) ?? '');
        i = j - 1;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  static String? _group(Match match, String numText) {
    final n = int.tryParse(numText);
    if (n == null || n < 0 || n > match.groupCount) return null;
    return match.group(n);
  }
}

/// 正则库：读写 + 批量应用（带一层内存缓存，气泡渲染时不用反复解析 JSON）。
class DisplayRegexLibrary {
  DisplayRegexLibrary._();

  static List<DisplayRegex>? _cache;

  static List<DisplayRegex> get all {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = AppSettings.displayRegexesJson;
    final list = <DisplayRegex>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            list.add(DisplayRegex.fromSillyTavern(item));
          }
        }
      } catch (_) {
        // 坏数据当空库，界面里重新导入即可
      }
    }
    _cache = list;
    return list;
  }

  static void invalidate() => _cache = null;

  static Future<void> save(List<DisplayRegex> regexes) async {
    _cache = List<DisplayRegex>.unmodifiable(regexes);
    await AppSettings.setDisplayRegexesJson(
      regexes.isEmpty ? null : jsonEncode([for (final r in regexes) r.toJson()]),
    );
  }

  static Future<void> upsert(DisplayRegex regex) async {
    final list = List<DisplayRegex>.of(all);
    final index = list.indexWhere((r) => r.id == regex.id);
    if (index >= 0) {
      list[index] = regex;
    } else {
      list.add(regex);
    }
    await save(list);
  }

  static Future<void> remove(String id) async {
    final list = List<DisplayRegex>.of(all)..removeWhere((r) => r.id == id);
    await save(list);
  }

  static List<DisplayRegex> sorted() {
    final list = List<DisplayRegex>.of(all);
    return list;
  }

  /// 按顺序应用所有启用且命中作用域的正则。
  static String apply(String text, {required bool isUser}) {
    if (text.isEmpty) return text;
    var out = text;
    for (final regex in all) {
      if (!regex.enabled) continue;
      if (!regex.matchesScope(isUser: isUser)) continue;
      out = regex.apply(out);
    }
    return out;
  }

  /// 导入 SillyTavern 的正则 JSON（数组或单个对象），返回新增条数。
  ///
  /// 防护（v0.41.0）：单条 pattern 超过 [DisplayRegex.maxPatternLength] 的条目会被跳过，
  /// 单次导入最多 [maxImportCount] 条，避免一次性灌入上万个正则把启动拖慢。
  static const int maxImportCount = 200;

  static Future<int> importFromJson(String raw) async {
    final decoded = jsonDecode(raw);
    final items = <Object?>[];
    if (decoded is List) {
      items.addAll(decoded);
    } else if (decoded is Map && decoded['entries'] is List) {
      items.addAll((decoded['entries'] as List));
    } else {
      items.add(decoded);
    }
    if (items.length > maxImportCount) {
      items.removeRange(maxImportCount, items.length);
    }
    final incoming = <DisplayRegex>[];
    for (var i = 0; i < items.length; i++) {
      final regex = DisplayRegex.fromSillyTavern(items[i],
          fallbackId: 'rx_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$i');
      if (regex.pattern.length > DisplayRegex.maxPatternLength) continue;
      incoming.add(regex);
    }
    if (incoming.isEmpty) return 0;
    final list = List<DisplayRegex>.of(all);
    var added = 0;
    for (final regex in incoming) {
      final index = list.indexWhere((r) => r.id == regex.id);
      if (index >= 0) {
        list[index] = regex;
      } else {
        list.add(regex);
        added++;
      }
    }
    await save(list);
    return added;
  }

  @visibleForTesting
  static void resetForTest() {
    _cache = null;
  }
}
