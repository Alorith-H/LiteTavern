import 'world_info.dart';

/// 归一化后的角色卡（兼容 SillyTavern V1/V2/V3）。
class CharacterCard {
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String mesExample;
  final String systemPrompt;
  final List<String> alternateGreetings;
  final List<String> tags;
  final String creator;

  /// 卡内嵌世界书，可能为 null
  final WorldInfo? characterBook;

  /// 卡内扩展字段（v0.33.0 起保留，用于只读展示脚本 / 变量等信息）
  final Map<String, dynamic> extensions;

  /// 角色 id（时间戳字符串），导入后由存储层生成
  final String id;

  const CharacterCard({
    required this.name,
    required this.description,
    required this.personality,
    required this.scenario,
    required this.firstMes,
    required this.mesExample,
    required this.systemPrompt,
    required this.alternateGreetings,
    required this.tags,
    required this.creator,
    this.characterBook,
    this.extensions = const <String, dynamic>{},
    this.id = '',
  });

  /// 从 V1 / V2 / V3 JSON 归一化。
  /// - 有 `spec` 且以 `chara_card` 开头 → 数据在 `data` 对象（V2/V3）
  /// - 无 `spec` 但有 `name` + `description` → V1，数据在顶层
  factory CharacterCard.fromJson(Map<String, dynamic> json) {
    final spec = json['spec'];
    Map<String, dynamic> data;
    if (spec is String && spec.startsWith('chara_card')) {
      final inner = json['data'];
      data = inner is Map<String, dynamic> ? inner : <String, dynamic>{};
    } else if (json.containsKey('name') && json.containsKey('description')) {
      data = json;
    } else {
      // 兜底：有 name 就当 V1
      data = json;
    }

    return CharacterCard(
      name: _str(data['name']),
      description: _str(data['description']),
      personality: _str(data['personality']),
      scenario: _str(data['scenario']),
      firstMes: _str(data['first_mes']),
      mesExample: _str(data['mes_example']),
      systemPrompt: _str(data['system_prompt']),
      alternateGreetings: _strList(data['alternate_greetings']),
      tags: _strList(data['tags']),
      creator: _str(data['creator']),
      characterBook: _parseBook(data['character_book']),
      extensions: _parseExtensions(data['extensions']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'spec': 'chara_card V3',
      'spec_version': '3.0',
      'data': {
        'name': name,
        'description': description,
        'personality': personality,
        'scenario': scenario,
        'first_mes': firstMes,
        'mes_example': mesExample,
        'system_prompt': systemPrompt,
        'alternate_greetings': alternateGreetings,
        'tags': tags,
        'creator': creator,
        'character_book': characterBook?.toSTJson(),
        if (extensions.isNotEmpty) 'extensions': extensions,
        if (extensions.isNotEmpty) 'extensions': extensions,
      },
    };
  }

  CharacterCard copyWith({
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMes,
    String? id,
    Map<String, dynamic>? extensions,
  }) {
    return CharacterCard(
      name: name ?? this.name,
      description: description ?? this.description,
      personality: personality ?? this.personality,
      scenario: scenario ?? this.scenario,
      firstMes: firstMes ?? this.firstMes,
      mesExample: mesExample,
      systemPrompt: systemPrompt,
      alternateGreetings: alternateGreetings,
      tags: tags,
      creator: creator,
      characterBook: characterBook,
      extensions: extensions ?? this.extensions,
      id: id ?? this.id,
    );
  }

  CharacterCard withId(String newId) => CharacterCard(
        name: name,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMes: firstMes,
        mesExample: mesExample,
        systemPrompt: systemPrompt,
        alternateGreetings: alternateGreetings,
        tags: tags,
        creator: creator,
        characterBook: characterBook,
        extensions: extensions,
        id: newId,
      );

  static String _str(dynamic v) => v is String ? v : '';

  static List<String> _strList(dynamic v) {
    if (v is List) return v.whereType<String>().toList();
    return [];
  }

  static Map<String, dynamic> _parseExtensions(dynamic v) {
    if (v is Map) {
      return v.map((k, value) => MapEntry('$k', value));
    }
    return const <String, dynamic>{};
  }

  static WorldInfo? _parseBook(dynamic v) {
    if (v is Map<String, dynamic>) {
      try {
        return WorldInfo.fromJson(v);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
