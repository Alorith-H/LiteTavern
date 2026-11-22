// 消息书签（v0.17.0）：把对话里值得回看的片段记下来，随时跳回去。
//
// 存储：prefs 键 `chat_bookmarks_<convId>` → [{timestamp, role, preview, createdAt}]
// - timestamp = 目标消息的时间戳（ChatMessage.timestamp，毫秒）
// - 同一会话内按 timestamp 去重；同一时间戳只留一条
// - 只存摘要文本（截 120 字），不复制整条消息，避免重复占空间
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ChatBookmark {
  final int timestamp;
  final String role;
  final String preview;
  final int createdAt;

  const ChatBookmark({
    required this.timestamp,
    required this.role,
    required this.preview,
    required this.createdAt,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'role': role,
        'preview': preview,
        'createdAt': createdAt,
      };

  factory ChatBookmark.fromJson(Map<String, dynamic> json) => ChatBookmark(
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        role: (json['role'] ?? 'assistant').toString(),
        preview: (json['preview'] ?? '').toString(),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );

  static String previewOf(String content, {int max = 120}) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= max) return flat;
    return '${flat.substring(0, max)}…';
  }
}

class BookmarkStore {
  static SharedPreferences? _sp;

  static Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  static void resetForTest() => _sp = null;

  static String _key(String convId) => 'chat_bookmarks_$convId';

  /// 按创建时间正序（老书签在前）返回。
  static Future<List<ChatBookmark>> load(String convId) async {
    if (convId.isEmpty) return [];
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key(convId));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <ChatBookmark>[];
      for (final item in decoded) {
        if (item is Map) {
          final b = ChatBookmark.fromJson(Map<String, dynamic>.from(item));
          if (b.timestamp != 0) out.add(b);
        }
      }
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String convId, List<ChatBookmark> bookmarks) async {
    if (convId.isEmpty) return;
    final prefs = await _prefs();
    if (bookmarks.isEmpty) {
      await prefs.remove(_key(convId));
      return;
    }
    await prefs.setString(
      _key(convId),
      jsonEncode([for (final b in bookmarks) b.toJson()]),
    );
  }

  static Future<bool> contains(String convId, int timestamp) async {
    if (timestamp == 0) return false;
    return (await load(convId)).any((b) => b.timestamp == timestamp);
  }

  /// 有则删、无则加。返回 true = 现在已加为书签。
  static Future<bool> toggle(String convId, ChatBookmark bookmark) async {
    final list = await load(convId);
    final idx = list.indexWhere((b) => b.timestamp == bookmark.timestamp);
    if (idx >= 0) {
      list.removeAt(idx);
      await save(convId, list);
      return false;
    }
    list.add(bookmark);
    await save(convId, list);
    return true;
  }

  static Future<void> remove(String convId, int timestamp) async {
    final list = await load(convId);
    final next = list.where((b) => b.timestamp != timestamp).toList();
    if (next.length != list.length) await save(convId, next);
  }

  /// 会话被删除时清掉它的书签。
  static Future<void> clear(String convId) async {
    if (convId.isEmpty) return;
    final prefs = await _prefs();
    await prefs.remove(_key(convId));
  }
}
