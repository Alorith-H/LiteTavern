// 单个角色 / 群聊下的「聊天文件」索引（v0.17.0）。
//
// 酒馆里同一个角色可以有很多个 chat（文件），这里用一份轻量索引来记录：
//   prefs 键 `chat_index_<owner>` → [{id, name, updatedAt, messageCount}, ...]
//
// - owner：单聊 = 角色 id；群聊 = `group_<群 id>`（与 Storage.groupConvId 同构）
// - id：会话存储 key，也就是 conversations/<id>.json 的文件名。
//   旧会话沿用历史 key（单聊 = 角色 id、群聊 = group_<群 id>），
//   新聊天用 `<owner>~<时间戳 36 进制>`，保证不冲突且文件名安全。
//
// 索引只影响「列出来 / 起名 / 排序」，聊天内容仍然由 Storage 读写。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ChatInfo {
  final String id;
  final String name;
  final int updatedAt;
  final int messageCount;

  const ChatInfo({
    required this.id,
    required this.name,
    this.updatedAt = 0,
    this.messageCount = 0,
  });

  ChatInfo copyWith({String? name, int? updatedAt, int? messageCount}) =>
      ChatInfo(
        id: id,
        name: name ?? this.name,
        updatedAt: updatedAt ?? this.updatedAt,
        messageCount: messageCount ?? this.messageCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'updatedAt': updatedAt,
        'messageCount': messageCount,
      };

  factory ChatInfo.fromJson(Map<String, dynamic> json) => ChatInfo(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'ChatInfo($id, $name, $messageCount)';
}

class ChatIndex {
  static SharedPreferences? _sp;

  static Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  /// 测试用：清掉缓存句柄（配合 SharedPreferences.setMockInitialValues）。
  static void resetForTest() => _sp = null;

  static String ownerOf({required String charId, String? groupId}) =>
      groupId != null ? 'group_$groupId' : charId;

  static String _key(String owner) => 'chat_index_$owner';

  /// 读索引（按最近使用倒序）。坏数据一律当空，不抛。
  static Future<List<ChatInfo>> load(String owner) async {
    if (owner.isEmpty) return [];
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key(owner));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <ChatInfo>[];
      for (final item in decoded) {
        if (item is Map) {
          final info = ChatInfo.fromJson(Map<String, dynamic>.from(item));
          if (info.id.isNotEmpty) out.add(info);
        }
      }
      return sorted(out);
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String owner, List<ChatInfo> chats) async {
    if (owner.isEmpty) return;
    final prefs = await _prefs();
    await prefs.setString(
      _key(owner),
      jsonEncode([for (final c in chats) c.toJson()]),
    );
  }

  /// 最近使用倒序（updatedAt 相同按名字稳定排）。
  static List<ChatInfo> sorted(List<ChatInfo> chats) {
    final out = List<ChatInfo>.of(chats);
    out.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      if (byTime != 0) return byTime;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// 首次升级到本版本时，把旧会话（[defaultId]）补进索引，避免「列表里没有历史聊天」。
  /// 已存在则原样返回；已有索引但缺旧会话时补一条。
  static Future<List<ChatInfo>> ensure(
    String owner, {
    required String defaultId,
    required String defaultName,
  }) async {
    final chats = await load(owner);
    if (chats.any((c) => c.id == defaultId)) return chats;
    final withDefault = [
      ...chats,
      ChatInfo(
        id: defaultId,
        name: chats.isEmpty ? defaultName : '$defaultName（默认）',
        updatedAt: chats.isEmpty ? _nowMs() : 0,
      ),
    ];
    await save(owner, withDefault);
    return sorted(withDefault);
  }

  static Future<ChatInfo?> find(String owner, String convId) async {
    for (final c in await load(owner)) {
      if (c.id == convId) return c;
    }
    return null;
  }

  /// 聊天保存后更新索引：不存在则新增，存在则刷新计数与时间。
  static Future<void> touch(
    String owner, {
    required String convId,
    required int messageCount,
    String? name,
    int? updatedAt,
  }) async {
    if (owner.isEmpty || convId.isEmpty) return;
    final chats = await load(owner);
    final now = updatedAt ?? _nowMs();
    final idx = chats.indexWhere((c) => c.id == convId);
    if (idx < 0) {
      chats.add(ChatInfo(
        id: convId,
        name: (name == null || name.trim().isEmpty) ? '未命名聊天' : name.trim(),
        updatedAt: now,
        messageCount: messageCount,
      ));
    } else {
      final old = chats[idx];
      chats[idx] = old.copyWith(
        name: (name == null || name.trim().isEmpty) ? old.name : name.trim(),
        updatedAt: now,
        messageCount: messageCount,
      );
    }
    await save(owner, chats);
  }

  static Future<void> rename(String owner, String convId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final chats = await load(owner);
    final idx = chats.indexWhere((c) => c.id == convId);
    if (idx < 0) return;
    chats[idx] = chats[idx].copyWith(name: trimmed);
    await save(owner, chats);
  }

  static Future<void> remove(String owner, String convId) async {
    final chats = await load(owner);
    final next = chats.where((c) => c.id != convId).toList();
    if (next.length != chats.length) await save(owner, next);
  }

  /// 新聊天的存储 key：`<owner>~<毫秒时间戳 36 进制>`。
  static String newId(String owner, {DateTime? now}) =>
      '$owner~${(now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36)}';

  /// 生成一个不重复的聊天名（「新聊天」「新聊天 2」…），[base] 可自定义。
  static Future<String> nextName(String owner, {String base = '新聊天'}) async {
    final chats = await load(owner);
    final used = {for (final c in chats) c.name};
    if (!used.contains(base)) return base;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base $i';
      if (!used.contains(candidate)) return candidate;
    }
    return '$base ${_nowMs()}';
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}
