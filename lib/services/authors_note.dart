import 'dart:convert';

import 'storage.dart';

/// 作者注释插在哪（v0.16.0，对齐 SillyTavern 的 Author's Note）。
enum AuthorNotePlacement {
  /// 角色设定（Scenario）之后、示例对话之前，作为 system 的一部分。
  afterScenario,

  /// 按深度插进聊天历史（越靠近最新消息，对下一条回复影响越大）。
  inChat,
}

/// 一条作者注释：一段临时的「写给我自己看」的指令，只在当前会话生效。
///
/// 典型用法：「回复控制在 3 段以内」「用书面语，不要用颜文字」
/// 「记住：主角左手有伤」。它不会出现在聊天记录里，只注入给模型。
class AuthorNote {
  final String content;
  final bool enabled;

  /// 插入深度：0 = 紧贴最后一条消息之后（最末尾）；仅 [AuthorNotePlacement.inChat] 生效。
  final int depth;

  /// 插入角色：'system' 或 'user'；仅 inChat 生效。
  final String role;

  final AuthorNotePlacement placement;

  const AuthorNote({
    this.content = '',
    this.enabled = true,
    this.depth = 0,
    this.role = 'system',
    this.placement = AuthorNotePlacement.inChat,
  });

  static const AuthorNote empty = AuthorNote();

  bool get isActive => enabled && content.trim().isNotEmpty;

  /// 注入用的文本（已 trim）。
  String get promptText => content.trim();

  AuthorNote copyWith({
    String? content,
    bool? enabled,
    int? depth,
    String? role,
    AuthorNotePlacement? placement,
  }) =>
      AuthorNote(
        content: content ?? this.content,
        enabled: enabled ?? this.enabled,
        depth: depth ?? this.depth,
        role: role ?? this.role,
        placement: placement ?? this.placement,
      );

  Map<String, dynamic> toJson() => {
        'content': content,
        'enabled': enabled,
        'depth': depth,
        'role': role,
        'placement': placement.name,
      };

  /// 容错解析：缺字段用默认值，非法值回落安全值（不抛）。
  factory AuthorNote.fromJson(Map<String, dynamic> json) {
    final rawRole = json['role'];
    final role = rawRole == 'user' ? 'user' : 'system';
    final rawDepth = json['depth'];
    var depth = rawDepth is int ? rawDepth : (rawDepth is num ? rawDepth.toInt() : 0);
    if (depth < 0) depth = 0;
    if (depth > 20) depth = 20;
    final rawPlacement = json['placement'];
    final placement = rawPlacement == AuthorNotePlacement.afterScenario.name
        ? AuthorNotePlacement.afterScenario
        : AuthorNotePlacement.inChat;
    return AuthorNote(
      content: json['content'] is String ? json['content'] as String : '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      depth: depth,
      role: role,
      placement: placement,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AuthorNote &&
      other.content == content &&
      other.enabled == enabled &&
      other.depth == depth &&
      other.role == role &&
      other.placement == placement;

  @override
  int get hashCode => Object.hash(content, enabled, depth, role, placement);

  @override
  String toString() =>
      'AuthorNote(enabled: $enabled, depth: $depth, role: $role, '
      'placement: ${placement.name})';
}

/// 作者注释的读写：会话级（key = convId）+ 一个默认值（新会话继承）。
class AuthorNoteStore {
  AuthorNoteStore._();

  static AuthorNote get defaultNote {
    final raw = AppSettings.defaultAuthorNoteJson;
    if (raw == null || raw.trim().isEmpty) return AuthorNote.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return AuthorNote.fromJson(decoded);
      if (decoded is Map) {
        return AuthorNote.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 损坏数据回退空
    }
    return AuthorNote.empty;
  }

  static set defaultNote(AuthorNote note) {
    AppSettings.defaultAuthorNoteJson = jsonEncode(note.toJson());
  }

  /// 读取某个会话的注释；没存过则回退默认值。
  static AuthorNote load(String convId) {
    final map = _readMap();
    final entry = map[convId];
    if (entry is Map<String, dynamic>) return AuthorNote.fromJson(entry);
    if (entry is Map) return AuthorNote.fromJson(Map<String, dynamic>.from(entry));
    return defaultNote;
  }

  static void save(String convId, AuthorNote note) {
    if (convId.isEmpty) return;
    final map = _readMap();
    map[convId] = note.toJson();
    _writeMap(map);
  }

  /// 删除会话级记录（之后重新继承默认值）。
  static void clear(String convId) {
    final map = _readMap();
    if (map.remove(convId) != null) _writeMap(map);
  }

  /// 会话是否真的有独立记录（用于「恢复默认」提示）。
  static bool hasOwn(String convId) => _readMap().containsKey(convId);

  static Map<String, dynamic> _readMap() {
    final raw = AppSettings.authorNotesJson;
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return Map<String, dynamic>.of(decoded);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 损坏数据按空处理
    }
    return <String, dynamic>{};
  }

  static void _writeMap(Map<String, dynamic> map) {
    AppSettings.authorNotesJson =
        map.isEmpty ? null : jsonEncode(map);
  }
}
