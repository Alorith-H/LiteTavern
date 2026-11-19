// 译文的本地持久化：SharedPreferences 里两个 JSON map。
//
// - `card_translations`：{角色 id: CardTranslation}  —— 已入库角色
// - `market_translations`：{fullPath: MarketCardTranslation} —— 市场列表缓存
//
// 市场译文按 updatedAt 做粗略淘汰（上限 400 条），避免长期使用后无限膨胀。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/card_translation.dart';
import '../models/character_card.dart';

class TranslationStore {
  static SharedPreferences? _sp;
  static const String _kCards = 'card_translations';
  static const String _kMarket = 'market_translations';
  static const String _kOriginals = 'card_originals';
  static const int _marketLimit = 400;

  static Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  /// 测试用：清掉缓存句柄（配合 SharedPreferences.setMockInitialValues）。
  static void resetForTest() => _sp = null;

  static Future<CardTranslation?> loadCard(String charId) async {
    if (charId.isEmpty) return null;
    final map = await _readMap(_kCards);
    final decoded = _decodeEntry(map[charId]);
    if (decoded == null) return null;
    final t = CardTranslation.fromJson(decoded);
    return t.isEmpty ? null : t;
  }

  static Future<void> saveCard(String charId, CardTranslation translation) async {
    if (charId.isEmpty) return;
    final map = await _readMap(_kCards);
    if (translation.isEmpty) {
      map.remove(charId);
    } else {
      map[charId] = jsonEncode(translation.toJson());
    }
    await _writeMap(_kCards, map);
  }

  static Future<void> removeCard(String charId) async {
    final map = await _readMap(_kCards);
    if (map.remove(charId) != null) await _writeMap(_kCards, map);
    final originals = await _readMap(_kOriginals);
    if (originals.remove(charId) != null) await _writeMap(_kOriginals, originals);
  }

  /// 译文应用前把原文（整张卡）备份下来，供「查看原文 / 恢复原文」。
  static Future<void> saveOriginalCard(String charId, CharacterCard card) async {
    if (charId.isEmpty) return;
    final map = await _readMap(_kOriginals);
    map[charId] = jsonEncode(card.toJson());
    await _writeMap(_kOriginals, map);
  }

  static Future<CharacterCard?> loadOriginalCard(String charId) async {
    if (charId.isEmpty) return null;
    final map = await _readMap(_kOriginals);
    final raw = map[charId];
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map) {
        return CharacterCard.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 备份损坏：当没有
    }
    return null;
  }

  static Future<bool> hasOriginalCard(String charId) async =>
      (await _readMap(_kOriginals)).containsKey(charId);

  static Future<MarketCardTranslation?> loadMarket(String fullPath) async {
    if (fullPath.isEmpty) return null;
    final map = await _readMap(_kMarket);
    final decoded = _decodeEntry(map[fullPath]);
    if (decoded == null) return null;
    final t = MarketCardTranslation.fromJson(decoded);
    return t.isEmpty ? null : t;
  }

  static Future<void> saveMarket(
      String fullPath, MarketCardTranslation translation) async {
    if (fullPath.isEmpty) return;
    final map = await _readMap(_kMarket);
    if (translation.isEmpty) {
      map.remove(fullPath);
    } else {
      map[fullPath] = jsonEncode(translation.toJson());
      if (map.length > _marketLimit) _prune(map);
    }
    await _writeMap(_kMarket, map);
  }

  /// 超出上限时按 updatedAt 淘汰最旧的一半。
  static void _prune(Map<String, dynamic> map) {
    final entries = map.entries.toList()
      ..sort((a, b) => _updatedAt(b.value).compareTo(_updatedAt(a.value)));
    final keep = entries.take(_marketLimit ~/ 2);
    map
      ..clear()
      ..addEntries(keep);
  }

  static int _updatedAt(Object? raw) {
    if (raw is Map) return (raw['updatedAt'] as num?)?.toInt() ?? 0;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return (decoded['updatedAt'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // 损坏的缓存条目直接当最旧
      }
    }
    return 0;
  }

  /// 缓存条目既可能是 Map（旧格式），也可能是 JSON 字符串（写入用 jsonEncode）。
  static Map<String, dynamic>? _decodeEntry(Object? raw) {
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 单条损坏：当作没有，不要影响其它条目
    }
    return null;
  }

  static Future<Map<String, dynamic>> _readMap(String key) async {
    final sp = await _prefs();
    final raw = sp.getString(key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 数据损坏：当作空，不要让翻译功能崩掉
    }
    return <String, dynamic>{};
  }

  static Future<void> _writeMap(String key, Map<String, dynamic> map) async {
    final sp = await _prefs();
    await sp.setString(key, jsonEncode(map));
  }
}
