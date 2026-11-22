import 'dart:convert';

import 'storage.dart';

/// 用户人设（v0.16.0，对齐 SillyTavern 的 Persona）。
///
/// 一套人设 = 你的名字 + 一段自我介绍（外貌/身份/性格/和角色关系）。
/// 选中的人设会在每次生成时注入 system，并把 `{{user}}` 换成该名字。
class UserPersona {
  final String id;

  /// 显示名，同时作为对话里你的称呼（写进 AppSettings.userName）。
  final String name;

  /// 人设描述；空 = 只改名不注入设定。
  final String description;

  const UserPersona({
    required this.id,
    required this.name,
    this.description = '',
  });

  bool get hasDescription => description.trim().isNotEmpty;

  /// 注入 system 的文本（已 trim）；空串表示不注入。
  String get promptText => description.trim();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
      };

  factory UserPersona.fromJson(Map<String, dynamic> json) => UserPersona(
        id: _str(json['id']),
        name: _str(json['name']),
        description: _str(json['description']),
      );

  UserPersona copyWith({String? name, String? description}) => UserPersona(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
      );

  @override
  bool operator ==(Object other) =>
      other is UserPersona &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() => 'UserPersona($id, $name)';

  static String _str(Object? v) => v is String ? v : '';
}

/// 人设的读写与选中状态（存 SharedPreferences，见 [AppSettings.personasJson]）。
///
/// 只有选中的人设会同步 `AppSettings.userName`，这样所有既有的
/// 名字展示 / 宏替换 / 历史渲染都无需改动即可跟随人设。
class PersonaStore {
  PersonaStore._();

  static String newId() =>
      'persona_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 读取人设列表；JSON 损坏时回退空列表（不抛）。
  static List<UserPersona> load() {
    final raw = AppSettings.personasJson;
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <UserPersona>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final p = UserPersona.fromJson(item);
          if (p.id.isNotEmpty && p.name.trim().isNotEmpty) out.add(p);
        } else if (item is Map) {
          final p = UserPersona.fromJson(Map<String, dynamic>.from(item));
          if (p.id.isNotEmpty && p.name.trim().isNotEmpty) out.add(p);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static void save(List<UserPersona> personas) {
    AppSettings.personasJson = personas.isEmpty
        ? null
        : jsonEncode([for (final p in personas) p.toJson()]);
  }

  static UserPersona? find(String? id) {
    if (id == null || id.isEmpty) return null;
    final list = load();
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 当前选中的人设；未选或已删除返回 null。
  static UserPersona? get active => find(AppSettings.activePersonaId);

  /// 对话里显示的你的名字：优先人设名，否则回退设置里的 userName。
  static String get activeName {
    final name = active?.name.trim() ?? '';
    return name.isEmpty ? AppSettings.userName : name;
  }

  /// 当前人设描述（空串 = 不注入）。
  static String get activeDescription => active?.promptText ?? '';

  /// 选中人设并同步 userName；id 为空则清空选中（保留 userName 原值）。
  static void setActive(String? id) {
    if (id == null || id.isEmpty) {
      AppSettings.activePersonaId = null;
      return;
    }
    final p = find(id);
    if (p == null) return;
    AppSettings.activePersonaId = p.id;
    final name = p.name.trim();
    if (name.isNotEmpty) AppSettings.userName = name;
  }

  /// 新增或更新（按 id 匹配）；返回保存后的对象（新对象带 id）。
  static UserPersona upsert(UserPersona persona) {
    final list = List<UserPersona>.of(load());
    final id = persona.id.trim().isEmpty ? newId() : persona.id;
    final saved = UserPersona(
      id: id,
      name: persona.name.trim(),
      description: persona.description.trim(),
    );
    final idx = list.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      list[idx] = saved;
    } else {
      list.add(saved);
    }
    save(list);
    if (AppSettings.activePersonaId == id) setActive(id);
    return saved;
  }

  /// 删除；删的是当前人设则清空选中（userName 保留，避免名字变空）。
  static void remove(String id) {
    final list = load().where((p) => p.id != id).toList();
    save(list);
    if (AppSettings.activePersonaId == id) AppSettings.activePersonaId = null;
  }

  /// 首次使用时把现有 userName 包装成一条「默认」人设并选中。
  /// 已有人设时直接返回（不改动）。
  static List<UserPersona> ensureSeeded() {
    final list = load();
    if (list.isNotEmpty) return list;
    final name = AppSettings.userName.trim();
    if (name.isEmpty) return list;
    final seed = UserPersona(id: newId(), name: name);
    save([seed]);
    AppSettings.activePersonaId = seed.id;
    return [seed];
  }
}
