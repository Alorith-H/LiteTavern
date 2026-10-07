import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/chat_group.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import 'hit_stats.dart';
import 'summarize.dart';

/// 会话文件内容：消息列表 + 可选的早期摘要 + 可选的世界书命中率统计。
class ConversationData {
  final List<ChatMessage> messages;
  final ChatSummary? summary;

  /// 旧会话无此字段 → null（界面不显示命中率，不迁移）。
  final HitStats? hitStats;

  const ConversationData({required this.messages, this.summary, this.hitStats});
}

/// 文件存储：角色 / 对话 / 世界书 / 群聊（纯 JSON，无数据库）。
class Storage {
  static late Directory _docs;

  static Future<void> init() async {
    _docs = await getApplicationDocumentsDirectory();
    for (final dir in ['characters', 'conversations', 'worldbooks', 'groups']) {
      await Directory('${_docs.path}/$dir').create(recursive: true);
    }
  }

  /// 测试用：跳过 path_provider，直接指定文档根目录。
  @visibleForTesting
  static void initForTest(Directory docs) {
    _docs = docs;
  }

  static Directory get _charRoot => Directory('${_docs.path}/characters');
  static Directory get _convRoot => Directory('${_docs.path}/conversations');
  static Directory get _wbRoot => Directory('${_docs.path}/worldbooks');
  static Directory get _groupRoot => Directory('${_docs.path}/groups');

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

  /// 读会话（含可选摘要）。兼容两种格式：
  /// 旧 = 消息数组；新 = `{messages, summary?}`（v0.6.0 起带摘要时用对象）。
  static Future<ConversationData> loadConversationData(String convId) async {
    final file = _convFile(convId);
    // 回归：fallback 必须是可增长列表 —— const 空列表不可 add，
    // 会话页拿到后 _doSend 落消息时抛 Unsupported operation。
    if (!await file.exists()) return ConversationData(messages: <ChatMessage>[]);
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        return ConversationData(
          messages: decoded
              .whereType<Map<String, dynamic>>()
              .map(ChatMessage.fromJson)
              .toList(),
        );
      }
      if (decoded is Map<String, dynamic>) {
        final raw = decoded['messages'];
        final messages = raw is List
            ? raw
                .whereType<Map<String, dynamic>>()
                .map(ChatMessage.fromJson)
                .toList()
            : <ChatMessage>[];
        final summaryRaw = decoded['summary'];
        final summary = summaryRaw is Map<String, dynamic>
            ? ChatSummary.fromJson(summaryRaw)
            : null;
        final statsRaw = decoded['hitStats'];
        final hitStats = statsRaw is Map<String, dynamic>
            ? HitStats.fromJson(statsRaw)
            : null;
        return ConversationData(
          messages: messages,
          summary: summary != null && summary.isEmpty ? null : summary,
          hitStats: hitStats != null && hitStats.isEmpty ? null : hitStats,
        );
      }
      return ConversationData(messages: <ChatMessage>[]);
    } catch (_) {
      return ConversationData(messages: <ChatMessage>[]);
    }
  }

  static Future<List<ChatMessage>> loadConversation(String convId) async =>
      (await loadConversationData(convId)).messages;

  /// 写会话。无摘要且无命中率统计时保持旧的数组格式（单聊文件字节不变）；
  /// 有摘要或命中率统计时写 `{messages, summary?, hitStats?}` 对象。
  static Future<void> saveConversation(
    String convId,
    List<ChatMessage> messages, {
    ChatSummary? summary,
    HitStats? hitStats,
  }) async {
    final file = _convFile(convId);
    final hasSummary = summary != null && !summary.isEmpty;
    final hasStats = hitStats != null && !hitStats.isEmpty;
    final data = !hasSummary && !hasStats
        ? messages.map((m) => m.toJson()).toList()
        : <String, dynamic>{
            'messages': [for (final m in messages) m.toJson()],
            if (hasSummary) 'summary': summary.toJson(),
            if (hasStats) 'hitStats': hitStats.toJson(),
          };
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  static Future<void> deleteConversation(String convId) async {
    final file = _convFile(convId);
    if (await file.exists()) await file.delete();
  }

  // ---------------------------------------------------------- 群聊 --

  static File _groupFile(String groupId) =>
      File('${_groupRoot.path}${Platform.pathSeparator}$groupId.json');

  /// 群聊会话 id（与单聊共用 conversations 目录）。
  static String groupConvId(String groupId) => 'group_$groupId';

  /// 读取全部群聊（创建时间倒序，新的在前）。
  static Future<List<ChatGroup>> loadGroups() async {
    final result = <ChatGroup>[];
    if (!await _groupRoot.exists()) return result;
    await for (final entity in _groupRoot.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final g = ChatGroup.fromJson(json);
        if (g.id.isNotEmpty) result.add(g);
      } catch (_) {
        // 损坏的群文件跳过
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  static Future<ChatGroup?> loadGroup(String id) async {
    final file = _groupFile(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final g = ChatGroup.fromJson(json);
      return g.id.isEmpty ? null : g;
    } catch (_) {
      return null;
    }
  }

  /// 保存群聊（含轮转指针）；id 为空时生成新 id。返回带 id 的群。
  static Future<ChatGroup> saveGroup(ChatGroup group) async {
    final id = group.id.isEmpty ? newId() : group.id;
    final saved = group.id.isEmpty
        ? ChatGroup(
            id: id,
            name: group.name,
            memberIds: group.memberIds,
            createdAt: group.createdAt,
            turnIndex: group.turnIndex,
          )
        : group;
    await _groupRoot.create(recursive: true);
    await _groupFile(id).writeAsString(jsonEncode(saved.toJson()), flush: true);
    return saved;
  }

  /// 删除群聊：群文件 + 级联删除其会话。
  static Future<void> deleteGroup(String id) async {
    final file = _groupFile(id);
    if (await file.exists()) await file.delete();
    await deleteConversation(groupConvId(id));
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

  /// 更新已存在世界书的内容（写回原 id 文件）。
  static Future<void> updateWorldBook(String id, WorldInfo book) async {
    final file = File('${_wbRoot.path}${Platform.pathSeparator}$id.json');
    await file.writeAsString(jsonEncode(book.toSTJson()), flush: true);
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

/// 一套 API 配置（v0.7.0 多配置）。存 SharedPreferences JSON 数组。
class ApiConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String key;
  final String model;

  const ApiConfig({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.key = '',
    this.model = '',
  });

  factory ApiConfig.fromJson(Map<String, dynamic> json) => ApiConfig(
        id: json['id'] is String ? json['id'] as String : '',
        name: json['name'] is String ? json['name'] as String : '',
        baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
        key: json['key'] is String ? json['key'] as String : '',
        model: json['model'] is String ? json['model'] as String : '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'key': key,
        'model': model,
      };

  ApiConfig copyWith({String? name, String? baseUrl, String? key, String? model}) =>
      ApiConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        key: key ?? this.key,
        model: model ?? this.model,
      );
}

/// 一套生成参数预设（v0.7.0）。存 SharedPreferences JSON 数组。
class GenPreset {
  final String id;
  final String name;

  /// 0–2，默认 0.8
  final double temperature;

  /// 0–1，默认 1.0
  final double topP;

  /// 0 = 不限（请求不带该字段）
  final int maxTokens;

  const GenPreset({
    required this.id,
    required this.name,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
  });

  factory GenPreset.fromJson(Map<String, dynamic> json) => GenPreset(
        id: json['id'] is String ? json['id'] as String : '',
        name: json['name'] is String ? json['name'] as String : '',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
        topP: (json['topP'] as num?)?.toDouble() ?? 1.0,
        maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'temperature': temperature,
        'topP': topP,
        'maxTokens': maxTokens,
      };

  GenPreset copyWith({String? name, double? temperature, double? topP, int? maxTokens}) =>
      GenPreset(
        id: id,
        name: name ?? this.name,
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        maxTokens: maxTokens ?? this.maxTokens,
      );
}

/// 应用设置（shared_preferences）。
class AppSettings {
  static late SharedPreferences _sp;
  static bool _ready = false;

  static Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
    _migrateApiConfig();
    _migrateGenPreset();
    _ready = true;
  }

  // ------------------------------------------------------------ 迁移 --

  /// 配置/预设 id：微秒时间戳 + 进程内序号（避免同毫秒碰撞）。
  static int _idSeq = 0;
  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';

  /// 供界面新建配置/预设时取 id。
  static String newConfigId() => _newId();

  /// 旧的单套 baseUrl/key/model → 名为「默认」的配置并激活（一次性）。
  /// `api_configs` 存在即已迁移过，不重复迁；旧字段迁完即删。
  /// 全新安装（无旧字段）也建一套空的「默认」，保证列表至少 1 套。
  static void _migrateApiConfig() {
    if (!_sp.containsKey(_kApiConfigs)) {
      final cfg = ApiConfig(
        id: _newId(),
        name: '默认',
        baseUrl: _sp.getString(_kBaseUrl) ?? '',
        key: _sp.getString(_kApiKey) ?? '',
        model: _sp.getString(_kModel) ?? '',
      );
      _sp.setString(_kApiConfigs, jsonEncode([cfg.toJson()]));
      _sp.setString(_kActiveApiCfg, cfg.id);
    }
    _sp.remove(_kBaseUrl);
    _sp.remove(_kApiKey);
    _sp.remove(_kModel);
  }

  /// 旧的 temperature/topP/maxTokens → 名为「默认」的预设（一次性）。
  /// 逻辑同上；全新安装默认 0.8 / 1.0 / 0。
  static void _migrateGenPreset() {
    if (!_sp.containsKey(_kGenPresets)) {
      final preset = GenPreset(
        id: _newId(),
        name: '默认',
        temperature: _sp.getDouble(_kTemperature) ?? 0.8,
        topP: _sp.getDouble(_kTopP) ?? 1.0,
        maxTokens: _sp.getInt(_kMaxTokens) ?? 0,
      );
      _sp.setString(_kGenPresets, jsonEncode([preset.toJson()]));
      _sp.setString(_kActivePreset, preset.id);
    }
    _sp.remove(_kTemperature);
    _sp.remove(_kTopP);
    _sp.remove(_kMaxTokens);
  }

  // ------------------------------------------------------ API 配置 --

  static const _kApiConfigs = 'api_configs';
  static const _kActiveApiCfg = 'active_api_config_id';

  static List<ApiConfig> get apiConfigs {
    try {
      final raw = _sp.getString(_kApiConfigs);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final list = decoded
              .whereType<Map<String, dynamic>>()
              .map(ApiConfig.fromJson)
              .where((c) => c.id.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      }
    } catch (_) {
      // 数据损坏时回落到默认单套
    }
    return const [
      ApiConfig(id: 'default', name: '默认'),
    ];
  }

  static set apiConfigs(List<ApiConfig> v) =>
      _sp.setString(_kApiConfigs, jsonEncode([for (final c in v) c.toJson()]));

  static ApiConfig get activeApiConfig {
    final list = apiConfigs;
    final id = _sp.getString(_kActiveApiCfg);
    for (final c in list) {
      if (c.id == id) return c;
    }
    return list.first;
  }

  /// 激活 id；不存在的 id 忽略（调用方读 activeApiConfig 拿到的是第一套）。
  static set activeApiConfigId(String v) {
    for (final c in apiConfigs) {
      if (c.id == v) {
        _sp.setString(_kActiveApiCfg, v);
        return;
      }
    }
  }

  /// 改写激活配置的字段（列表里原位替换）。
  static void _updateActiveApi(ApiConfig Function(ApiConfig) f) {
    final list = List.of(apiConfigs);
    final active = activeApiConfig;
    final i = list.indexWhere((c) => c.id == active.id);
    final updated = f(active);
    if (i < 0) {
      list.add(updated);
      _sp.setString(_kActiveApiCfg, updated.id);
    } else {
      list[i] = updated;
    }
    apiConfigs = list;
  }

  /// 删除配置：至少保留 1 套（剩最后一套时不生效）；
  /// 删掉激活项 → 自动激活第一套。
  static void deleteApiConfig(String id) {
    final list = apiConfigs;
    if (list.length <= 1) return;
    final next = list.where((c) => c.id != id).toList();
    if (next.length == list.length) return; // id 不存在
    apiConfigs = next;
    if (_sp.getString(_kActiveApiCfg) == id) {
      _sp.setString(_kActiveApiCfg, next.first.id);
    }
  }

  /// 出网统一读激活配置（聊天/继续/摘要/测试共用）。
  static String get baseUrl => activeApiConfig.baseUrl;
  static set baseUrl(String v) =>
      _updateActiveApi((c) => c.copyWith(baseUrl: v.trim()));

  static String get apiKey => activeApiConfig.key;
  static set apiKey(String v) =>
      _updateActiveApi((c) => c.copyWith(key: v.trim()));

  static String get model => activeApiConfig.model;
  static set model(String v) =>
      _updateActiveApi((c) => c.copyWith(model: v.trim()));

  // ------------------------------------------------------ 生成参数 --

  static const _kGenPresets = 'gen_presets';
  static const _kActivePreset = 'active_preset_id';

  // 旧的单套生成参数字段（仅迁移时读取，迁完即删）
  static const _kTemperature = 'temperature';
  static const _kTopP = 'top_p';
  static const _kMaxTokens = 'max_tokens';

  static List<GenPreset> get genPresets {
    try {
      final raw = _sp.getString(_kGenPresets);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final list = decoded
              .whereType<Map<String, dynamic>>()
              .map(GenPreset.fromJson)
              .where((p) => p.id.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      }
    } catch (_) {
      // 数据损坏时回落到默认单套
    }
    return const [
      GenPreset(
        id: 'default',
        name: '默认',
        temperature: 0.8,
        topP: 1.0,
        maxTokens: 0,
      ),
    ];
  }

  static set genPresets(List<GenPreset> v) =>
      _sp.setString(_kGenPresets, jsonEncode([for (final p in v) p.toJson()]));

  static GenPreset get activePreset {
    final list = genPresets;
    final id = _sp.getString(_kActivePreset);
    for (final p in list) {
      if (p.id == id) return p;
    }
    return list.first;
  }

  static set activePresetId(String v) {
    for (final p in genPresets) {
      if (p.id == v) {
        _sp.setString(_kActivePreset, v);
        return;
      }
    }
  }

  static void _updateActivePreset(GenPreset Function(GenPreset) f) {
    final list = List.of(genPresets);
    final active = activePreset;
    final i = list.indexWhere((p) => p.id == active.id);
    if (i < 0) {
      list.add(f(active));
    } else {
      list[i] = f(active);
    }
    genPresets = list;
  }

  /// 删除预设：至少保留 1 套；删掉激活项 → 自动激活第一套。
  static void deletePreset(String id) {
    final list = genPresets;
    if (list.length <= 1) return;
    final next = list.where((p) => p.id != id).toList();
    if (next.length == list.length) return;
    genPresets = next;
    if (_sp.getString(_kActivePreset) == id) {
      _sp.setString(_kActivePreset, next.first.id);
    }
  }

  /// 生成温度，0–2，默认 0.8（读写都落在激活预设上）。
  static double get temperature => activePreset.temperature;
  static set temperature(double v) =>
      _updateActivePreset((p) => p.copyWith(temperature: v));

  /// Top-p，0–1，默认 1.0（同上）。
  static double get topP => activePreset.topP;
  static set topP(double v) => _updateActivePreset((p) => p.copyWith(topP: v));

  /// 最大回复长度；0 = 不限（请求里不带该字段，同上）。
  static int get maxTokens => activePreset.maxTokens;
  static set maxTokens(int v) =>
      _updateActivePreset((p) => p.copyWith(maxTokens: v));

  /// 设置是否已加载（未初始化时读取默认值，供纯逻辑模块兜底）
  static bool get initialized => _ready;

  static const _kBaseUrl = 'api_base_url';
  static const _kApiKey = 'api_key';
  static const _kModel = 'model';
  static const _kUserName = 'user_name';
  static const _kTheme = 'theme_mode';
  static const _kOnboarding = 'onboarding_done';
  static const _kMountedWb = 'mounted_worldbooks';

  static String get userName => _sp.getString(_kUserName) ?? '你';
  static set userName(String v) => _sp.setString(_kUserName, v);

  /// 'system' | 'light' | 'dark'
  static String get themeMode => _sp.getString(_kTheme) ?? 'system';
  static set themeMode(String v) => _sp.setString(_kTheme, v);

  /// 主题色 seed（0xFFRRGGBB）：从未设置过时用赤陶酒红默认值，
  /// 用户已选过的颜色保留在 prefs 不受影响。
  static int get themeSeed => _sp.getInt(_kThemeSeed) ?? 0xFF9C4632;
  static set themeSeed(int v) => _sp.setInt(_kThemeSeed, v);
  static const _kThemeSeed = 'theme_seed';

  /// 快捷回复文本列表；从未管理过时给预置两条，
  /// 主动删到空后存空列表（聊天页据此隐藏快捷回复排）。
  static List<String> get quickReplies =>
      _sp.getStringList(_kQuickReplies) ?? const ['继续', '换个说法'];
  static set quickReplies(List<String> v) => _sp.setStringList(_kQuickReplies, v);
  static const _kQuickReplies = 'quick_replies';

  /// 聊天页是否显示快捷回复排，默认关闭（无记录 = 关）。
  /// 关闭时输入框上方完全不渲染 chips 行；已存的快捷回复数据不动。
  static bool get showQuickReplies => _sp.getBool(_kShowQuickReplies) ?? false;
  static set showQuickReplies(bool v) => _sp.setBool(_kShowQuickReplies, v);
  static const _kShowQuickReplies = 'show_quick_replies';

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
  static const _kContextWindow = 'model_context_window';

  /// 模型上下文窗口（token），默认 65536；
  /// 0 = 关闭上下文占用%显示与发送前自动压缩。
  /// 默认值只在这里写一次，各处一律读本 getter。
  static int get contextWindow =>
      (_sp.getInt(_kContextWindow) ?? 65536).clamp(0, 1 << 30).toInt();

  static set contextWindow(int v) =>
      _sp.setInt(_kContextWindow, v.clamp(0, 1 << 30).toInt());

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

  static const _kAutoContinue = 'auto_continue_count';
  static const _kAutoSummarize = 'auto_summarize';

  /// 自动继续次数，0–5，默认 2（0 = 关闭）。
  /// 回复达到长度上限（completion ≥ max_tokens×0.98）时代写续接。
  static int get autoContinueCount =>
      (_sp.getInt(_kAutoContinue) ?? 2).clamp(0, 5).toInt();
  static set autoContinueCount(int v) =>
      _sp.setInt(_kAutoContinue, v.clamp(0, 5));

  /// 长对话自动摘要开关，默认开。
  static bool get autoSummarize => _sp.getBool(_kAutoSummarize) ?? true;
  static set autoSummarize(bool v) => _sp.setBool(_kAutoSummarize, v);

  static bool get apiConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}
