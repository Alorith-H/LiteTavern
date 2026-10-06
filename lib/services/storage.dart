import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';

/// 文件存储：角色 / 对话 / 世界书（纯 JSON，无数据库）。
class Storage {
  static late Directory _docs;

  static Future<void> init() async {
    _docs = await getApplicationDocumentsDirectory();
    for (final dir in ['characters', 'conversations', 'worldbooks']) {
      await Directory('${_docs.path}/$dir').create(recursive: true);
    }
  }

  static Directory get _charRoot => Directory('${_docs.path}/characters');
  static Directory get _convRoot => Directory('${_docs.path}/conversations');
  static Directory get _wbRoot => Directory('${_docs.path}/worldbooks');

  /// id 用时间戳字符串
  static String newId() => DateTime.now().millisecondsSinceEpoch.toString();

  // ------------------------------------------------------------ 角色 --

  static Directory _charDir(String id) => Directory('${_charRoot.path}/$id');

  /// 读取全部角色卡（id 倒序，新的在前）。
  static Future<List<CharacterCard>> loadCharacters() async {
    final result = <CharacterCard>[];
    if (!await _charRoot.exists()) return result;
    await for (final entity in _charRoot.list()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      final file = File('${entity.path}${Platform.pathSeparator}card.json');
      if (!await file.exists()) continue;
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        result.add(CharacterCard.fromJson(json).withId(id));
      } catch (_) {
        // 损坏的角色卡跳过
      }
    }
    result.sort((a, b) {
      final ia = int.tryParse(a.id) ?? 0;
      final ib = int.tryParse(b.id) ?? 0;
      return ib.compareTo(ia);
    });
    return result;
  }

  static Future<CharacterCard?> loadCharacter(String id) async {
    final file =
        File('${_charDir(id).path}${Platform.pathSeparator}card.json');
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return CharacterCard.fromJson(json).withId(id);
    } catch (_) {
      return null;
    }
  }

  /// 保存角色卡；id 为空时生成新 id。返回带 id 的卡。
  static Future<CharacterCard> saveCharacter(CharacterCard card) async {
    final id = card.id.isEmpty ? newId() : card.id;
    final saved = card.withId(id);
    final dir = _charDir(id);
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}card.json')
        .writeAsString(jsonEncode(saved.toJson()), flush: true);
    return saved;
  }

  /// 导入 PNG 卡时保存原图为头像。
  static Future<void> saveAvatar(String id, Uint8List bytes) async {
    final dir = _charDir(id);
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}avatar.png')
        .writeAsBytes(bytes, flush: true);
  }

  /// 头像文件（不存在返回 null）。同步返回供 Image.file 直接用。
  static File? avatarFile(String id) {
    final f = File('${_charDir(id).path}${Platform.pathSeparator}avatar.png');
    return f.existsSync() ? f : null;
  }

  static Future<void> deleteCharacter(String id) async {
    final dir = _charDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    await deleteConversation(id);
    await removeWorldBookMounts(id);
  }

  // ---------------------------------------------------------- 对话 --

  static File _convFile(String charId) =>
      File('${_convRoot.path}${Platform.pathSeparator}$charId.json');

  static Future<List<ChatMessage>> loadConversation(String charId) async {
    final file = _convFile(charId);
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveConversation(
      String charId, List<ChatMessage> messages) async {
    final file = _convFile(charId);
    await file.writeAsString(
      jsonEncode(messages.map((m) => m.toJson()).toList()),
      flush: true,
    );
  }

  static Future<void> deleteConversation(String charId) async {
    final file = _convFile(charId);
    if (await file.exists()) await file.delete();
  }

  // -------------------------------------------------------- 世界书 --

  /// 保存世界书，返回其 id。
  static Future<String> saveWorldBook(WorldInfo book) async {
    final id = newId();
    final file = File(
        '${_wbRoot.path}${Platform.pathSeparator}$id.json');
    await file.writeAsString(jsonEncode(book.toSTJson()), flush: true);
    return id;
  }

  /// 加载全部世界书，返回 (id, 世界书)。
  static Future<List<(String, WorldInfo)>> loadWorldBooks() async {
    final result = <(String, WorldInfo)>[];
    if (!await _wbRoot.exists()) return result;
    await for (final entity in _wbRoot.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = entity.path
          .split(Platform.pathSeparator)
          .last
          .replaceAll('.json', '');
      if (id == 'mounts') continue; // 挂载关系文件，不是世界书
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        result.add((id, WorldInfo.fromJson(json)));
      } catch (_) {
        // 损坏的文件跳过
      }
    }
    result.sort((a, b) {
      final ia = int.tryParse(a.$1) ?? 0;
      final ib = int.tryParse(b.$1) ?? 0;
      return ib.compareTo(ia);
    });
    return result;
  }

  static Future<void> deleteWorldBook(String id) async {
    final file = File('${_wbRoot.path}${Platform.pathSeparator}$id.json');
    if (await file.exists()) await file.delete();
    await unmountWorldBook(id);
  }

  // --------------------------------------------------- 世界书挂载 --

  /// 每角色挂载关系：`{ charId: [{id, enabled}] }`，存 worldbooks/mounts.json。
  static File get _mountsFile =>
      File('${_wbRoot.path}${Platform.pathSeparator}mounts.json');

  static Future<Map<String, List<({String id, bool enabled})>>>
      _readAllMounts() async {
    if (!await _mountsFile.exists()) return {};
    try {
      final decoded = jsonDecode(await _mountsFile.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, List<({String id, bool enabled})>>{};
      decoded.forEach((charId, v) {
        if (v is! List) return;
        final items = <({String id, bool enabled})>[];
        for (final e in v) {
          if (e is Map && e['id'] is String) {
            items.add((id: e['id'] as String, enabled: e['enabled'] != false));
          }
        }
        result[charId] = items;
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeAllMounts(
      Map<String, List<({String id, bool enabled})>> all) async {
    final data = <String, dynamic>{
      for (final e in all.entries)
        e.key: [
          for (final m in e.value) {'id': m.id, 'enabled': m.enabled},
        ],
    };
    await _mountsFile.writeAsString(jsonEncode(data), flush: true);
  }

  /// 该角色的挂载配置；null 表示从未配置过（调用方回退到全局默认挂载）。
  static Future<List<({String id, bool enabled})>?> worldBookMountsFor(
      String charId) async {
    final all = await _readAllMounts();
    return all[charId];
  }

  static Future<void> saveWorldBookMounts(
      String charId, List<({String id, bool enabled})> mounts) async {
    final all = await _readAllMounts();
    all[charId] = mounts;
    await _writeAllMounts(all);
  }

  static Future<void> removeWorldBookMounts(String charId) async {
    final all = await _readAllMounts();
    if (all.remove(charId) == null) return;
    await _writeAllMounts(all);
  }

  /// 世界书被删除时，从所有角色的挂载里移除。
  static Future<void> unmountWorldBook(String worldId) async {
    final all = await _readAllMounts();
    var changed = false;
    for (final e in all.entries) {
      final filtered = e.value.where((m) => m.id != worldId).toList();
      if (filtered.length != e.value.length) {
        all[e.key] = filtered;
        changed = true;
      }
    }
    if (changed) await _writeAllMounts(all);
  }
}

/// 应用设置（shared_preferences）。
class AppSettings {
  static late SharedPreferences _sp;
  static bool _ready = false;

  static Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
    _ready = true;
  }

  /// 设置是否已加载（未初始化时读取默认值，供纯逻辑模块兜底）
  static bool get initialized => _ready;

  static const _kBaseUrl = 'api_base_url';
  static const _kApiKey = 'api_key';
  static const _kModel = 'model';
  static const _kUserName = 'user_name';
  static const _kTheme = 'theme_mode';
  static const _kOnboarding = 'onboarding_done';
  static const _kMountedWb = 'mounted_worldbooks';

  static String get baseUrl => _sp.getString(_kBaseUrl) ?? '';
  static set baseUrl(String v) => _sp.setString(_kBaseUrl, v.trim());

  static String get apiKey => _sp.getString(_kApiKey) ?? '';
  static set apiKey(String v) => _sp.setString(_kApiKey, v.trim());

  static String get model => _sp.getString(_kModel) ?? '';
  static set model(String v) => _sp.setString(_kModel, v.trim());

  static String get userName => _sp.getString(_kUserName) ?? '你';
  static set userName(String v) => _sp.setString(_kUserName, v);

  /// 'system' | 'light' | 'dark'
  static String get themeMode => _sp.getString(_kTheme) ?? 'system';
  static set themeMode(String v) => _sp.setString(_kTheme, v);

  static bool get onboardingDone => _sp.getBool(_kOnboarding) ?? false;
  static set onboardingDone(bool v) => _sp.setBool(_kOnboarding, v);

  /// 已挂载（启用）的用户世界书 id 列表（角色未单独配置时的全局默认）
  static List<String> get mountedWorldBookIds =>
      _sp.getStringList(_kMountedWb) ?? const [];
  static set mountedWorldBookIds(List<String> v) =>
      _sp.setStringList(_kMountedWb, v);

  static const _kChatFontSize = 'chat_font_size';
  static const _kHistoryLimit = 'context_history_limit';
  static const _kShowTimestamps = 'show_timestamps';

  /// 聊天气泡字号（sp），13–20，默认 15（读取时钳制为整数步进值）
  static double get chatFontSize {
    final v = _sp.getDouble(_kChatFontSize) ?? 15;
    return v.roundToDouble().clamp(13, 20).toDouble();
  }

  static set chatFontSize(double v) => _sp.setDouble(_kChatFontSize, v);

  /// 上下文保留的历史条数，10–100，默认 40
  static int get contextHistoryLimit => _sp.getInt(_kHistoryLimit) ?? 40;
  static set contextHistoryLimit(int v) => _sp.setInt(_kHistoryLimit, v);

  /// 消息时间戳显示开关，默认关
  static bool get showTimestamps => _sp.getBool(_kShowTimestamps) ?? false;
  static set showTimestamps(bool v) => _sp.setBool(_kShowTimestamps, v);

  static const _kTemperature = 'temperature';
  static const _kTopP = 'top_p';
  static const _kMaxTokens = 'max_tokens';

  /// 生成温度，0–2，默认 0.8
  static double get temperature => _sp.getDouble(_kTemperature) ?? 0.8;
  static set temperature(double v) => _sp.setDouble(_kTemperature, v);

  /// Top-p，0–1，默认 1.0
  static double get topP => _sp.getDouble(_kTopP) ?? 1.0;
  static set topP(double v) => _sp.setDouble(_kTopP, v);

  /// 最大回复长度；0 = 不限（请求里不带该字段）
  static int get maxTokens => _sp.getInt(_kMaxTokens) ?? 0;
  static set maxTokens(int v) => _sp.setInt(_kMaxTokens, v);

  static bool get apiConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}
