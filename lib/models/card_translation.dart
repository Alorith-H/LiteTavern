// 角色卡/市场条目的中文译文（原文始终保留在原卡上，译文单独存放）。
//
// 存法：SharedPreferences 里两个 JSON map（按角色 id / 市场 fullPath 索引），
// 结构见 [TranslationStore]；删角色时同步清理，避免脏数据无限增长。

/// 已入库角色卡的译文（各字段与 [CharacterCard] 对应）。
class CardTranslation {
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String mesExample;
  final List<String> tags;

  /// 实际干活的翻译源（用户可见，便于判断质量/来源）。
  final String provider;
  final int updatedAt;

  const CardTranslation({
    this.name = '',
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.mesExample = '',
    this.tags = const <String>[],
    this.provider = '',
    this.updatedAt = 0,
  });

  bool get isEmpty =>
      name.isEmpty &&
      description.isEmpty &&
      personality.isEmpty &&
      scenario.isEmpty &&
      firstMes.isEmpty &&
      mesExample.isEmpty &&
      tags.isEmpty;

  CardTranslation copyWith({
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMes,
    String? mesExample,
    List<String>? tags,
    String? provider,
    int? updatedAt,
  }) =>
      CardTranslation(
        name: name ?? this.name,
        description: description ?? this.description,
        personality: personality ?? this.personality,
        scenario: scenario ?? this.scenario,
        firstMes: firstMes ?? this.firstMes,
        mesExample: mesExample ?? this.mesExample,
        tags: tags ?? this.tags,
        provider: provider ?? this.provider,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory CardTranslation.fromJson(Map<String, dynamic> json) => CardTranslation(
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        personality: (json['personality'] ?? '').toString(),
        scenario: (json['scenario'] ?? '').toString(),
        firstMes: (json['firstMes'] ?? '').toString(),
        mesExample: (json['mesExample'] ?? '').toString(),
        tags: [
          for (final t in (json['tags'] as List? ?? const []))
            if (t.toString().trim().isNotEmpty) t.toString().trim(),
        ],
        provider: (json['provider'] ?? '').toString(),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'personality': personality,
        'scenario': scenario,
        'firstMes': firstMes,
        'mesExample': mesExample,
        'tags': tags,
        'provider': provider,
        'updatedAt': updatedAt,
      };
}

/// 市场卡片列表用的轻量译文（名字 / 简介 / 标签）。
class MarketCardTranslation {
  final String name;
  final String description;
  final List<String> tags;
  final String provider;
  final int updatedAt;

  const MarketCardTranslation({
    this.name = '',
    this.description = '',
    this.tags = const <String>[],
    this.provider = '',
    this.updatedAt = 0,
  });

  bool get isEmpty => name.isEmpty && description.isEmpty && tags.isEmpty;

  factory MarketCardTranslation.fromJson(Map<String, dynamic> json) =>
      MarketCardTranslation(
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        tags: [
          for (final t in (json['tags'] as List? ?? const []))
            if (t.toString().trim().isNotEmpty) t.toString().trim(),
        ],
        provider: (json['provider'] ?? '').toString(),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'tags': tags,
        'provider': provider,
        'updatedAt': updatedAt,
      };
}
