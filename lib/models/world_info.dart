/// 世界书条目（SillyTavern World Info 格式，容错解析）。
class WorldInfoEntry {
  /// 主关键词（别名 keys）
  final List<String> keys;

  /// 次级关键词（别名 keysecondary）
  final List<String> keysSecondary;
  final String content;

  /// 升序排列用
  final int insertionOrder;
  final bool disabled;

  /// 1~100，useProbability 为 true 时按百分比随机激活
  final int probability;
  final bool useProbability;

  /// 0=系统提示词注入 / 1=聊天中深度注入 / 2=角色设定后注入（MVP 全部注入系统提示）
  final int position;
  final int depth;
  final bool recursive;
  final int scanDepth;
  final double groupWeight;

  const WorldInfoEntry({
    required this.keys,
    required this.keysSecondary,
    required this.content,
    required this.insertionOrder,
    required this.disabled,
    required this.probability,
    required this.useProbability,
    required this.position,
    required this.depth,
    required this.recursive,
    required this.scanDepth,
    required this.groupWeight,
  });

  factory WorldInfoEntry.fromJson(Map<String, dynamic> json) {
    return WorldInfoEntry(
      keys: _strList(json['key'] ?? json['keys']),
      keysSecondary: _strList(json['keysecondary'] ?? json['key_secondary']),
      content: json['content'] is String ? json['content'] as String : '',
      insertionOrder: _int(json['insertion_order'] ?? json['insert_order']),
      disabled: json['disabled'] == true,
      probability: _int(json['probability'], 100),
      useProbability: json['useProbability'] == true,
      position: _int(json['position']),
      depth: _int(json['depth'], 4),
      recursive: json['recursive'] == true,
      scanDepth: _int(json['scanDepth'], 50),
      groupWeight: (json['groupWeight'] as num?)?.toDouble() ?? 100,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': keys,
      'keysecondary': keysSecondary,
      'content': content,
      'insertion_order': insertionOrder,
      'disabled': disabled,
      'probability': probability,
      'useProbability': useProbability,
      'position': position,
      'depth': depth,
      'recursive': recursive,
      'scanDepth': scanDepth,
      'groupWeight': groupWeight,
    };
  }

  static List<String> _strList(dynamic v) {
    if (v is List) return v.whereType<String>().toList();
    if (v is String) return [v];
    return [];
  }

  static int _int(dynamic v, [int fallback = 0]) =>
      v is num ? v.toInt() : fallback;
}

/// 世界书：顶层 `{ name, description?, entries }`，
/// entries 兼容对象（key 为 id 字符串）与数组两种形式。
class WorldInfo {
  final String name;
  final String description;
  final List<WorldInfoEntry> entries;

  const WorldInfo({
    required this.name,
    required this.description,
    required this.entries,
  });

  factory WorldInfo.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final desc = json['description'];
    final raw = json['entries'];
    final entries = <WorldInfoEntry>[];
    if (raw is Map) {
      // 对象形式：key 为条目 id
      for (final v in raw.values) {
        if (v is Map<String, dynamic>) {
          entries.add(WorldInfoEntry.fromJson(v));
        }
      }
    } else if (raw is List) {
      for (final v in raw) {
        if (v is Map<String, dynamic>) {
          entries.add(WorldInfoEntry.fromJson(v));
        }
      }
    }
    return WorldInfo(
      name: name is String ? name : '',
      description: desc is String ? desc : '',
      entries: entries,
    );
  }

  Map<String, dynamic> toSTJson() {
    return {
      'name': name,
      'description': description,
      'entries': {
        for (var i = 0; i < entries.length; i++)
          '$i': entries[i].toJson(),
      },
    };
  }
}
