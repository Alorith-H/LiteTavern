import '../models/character_card.dart';
import '../models/chat_message.dart';

/// 导入体检（v0.32.0）：告诉用户「这张卡 / 这段聊天能用到什么程度、哪些内容被忽略了」。
///
/// 三档：
/// * [usable]       全部关键字段都在，能完整用；
/// * [partial]      能用，但缺了开场白/描述之类，体验会打折；
/// * [preserveOnly] 只能存下来（连描述和开场白都没有），基本只能当收藏。
enum ImportFit { usable, partial, preserveOnly }

extension ImportFitLabel on ImportFit {
  String get label => switch (this) {
        ImportFit.usable => '可用',
        ImportFit.partial => '部分可用',
        ImportFit.preserveOnly => '只保留',
      };

  bool get isWarning => this != ImportFit.usable;
}

/// 一条体检结论。
class ImportFinding {
  /// 简短标题，如「缺少开场白」。
  final String title;

  /// 细节说明（可以带字段名/扩展名）。
  final String detail;

  /// true = 提醒（内容会丢失或体验打折），false = 只是信息。
  final bool isWarning;

  const ImportFinding(this.title, this.detail, {this.isWarning = false});

  @override
  String toString() => '$title：$detail';
}

/// 一次导入的体检报告。
class ImportReport {
  final ImportFit fit;
  final String summary;
  final List<ImportFinding> findings;

  const ImportReport({
    required this.fit,
    required this.summary,
    this.findings = const [],
  });

  static const ImportReport empty = ImportReport(
    fit: ImportFit.usable,
    summary: '没有发现需要提醒的内容',
  );

  bool get hasWarnings => findings.any((f) => f.isWarning);
}

/// 角色卡体检：检查关键字段、识别不支持的扩展与未知字段（只读展示）。
class ImportAnalyzer {
  /// 角色卡标准字段（v2 / v3 常见写法都算）。
  static const Set<String> knownCardKeys = {
    'spec', 'spec_version', 'data', 'name', 'description', 'personality',
    'scenario', 'first_mes', 'mes_example', 'system_prompt', 'post_history_instructions',
    'alternate_greetings', 'tags', 'creator', 'character_version', 'character_book',
    'extensions', 'avatar', 'create_date', 'talkativeness', 'fav', 'chat',
  };

  /// 已知但本轮不消费的扩展键（只读列出，不执行）。
  static const Set<String> unsupportedExtensions = {
    'regex_scripts',
    'mvu',
    'depth_prompt',
    'world',
    'tavern_helper',
    'st-script',
    'stscript',
  };

  static ImportReport forCard(
    Map<String, dynamic> raw,
    CharacterCard card, {
    bool hasAvatar = false,
    int assetCount = 0,
  }) {
    final findings = <ImportFinding>[];
    final data = raw['data'] is Map<String, dynamic>
        ? (raw['data'] as Map<String, dynamic>)
        : raw;

    if (card.description.trim().isEmpty) {
      findings.add(const ImportFinding(
        '没有描述',
        '模型几乎只能靠名字和场景发挥，建议补上角色设定。',
        isWarning: true,
      ));
    }
    if (card.firstMes.trim().isEmpty &&
        card.alternateGreetings.every((g) => g.trim().isEmpty)) {
      findings.add(const ImportFinding(
        '没有开场白',
        '进聊天时会是一片空白，需要你先把第一句补上。',
        isWarning: true,
      ));
    } else if (card.firstMes.trim().isEmpty) {
      findings.add(const ImportFinding(
        '只有备用开场白',
        '默认开场白为空，会从备用开场白里取第一条。',
      ));
    }
    if (card.personality.trim().isEmpty &&
        card.scenario.trim().isEmpty &&
        card.systemPrompt.trim().isEmpty) {
      findings.add(const ImportFinding(
        '没有性格 / 场景 / 系统提示',
        '角色会完全依赖描述来演，长对话里容易跑偏。',
        isWarning: true,
      ));
    }
    if (card.mesExample.trim().isEmpty) {
      findings.add(const ImportFinding(
        '没有示例对话',
        '有示例对话的卡通常更像原角色，这里没有也不影响使用。',
      ));
    }

    final book = card.characterBook;
    if (book != null && book.entries.isNotEmpty) {
      findings.add(ImportFinding(
        '带世界书',
        '卡内世界书 ${book.entries.length} 条，已一并导入。',
      ));
    }
    if (card.alternateGreetings.isNotEmpty) {
      findings.add(ImportFinding(
        '备用开场白 ${card.alternateGreetings.length} 条',
        '聊天页可以切换开场白。',
      ));
    }
    if (!hasAvatar) {
      findings.add(const ImportFinding(
        '没有头像',
        '会用名字首字生成占位头像。',
      ));
    }
    if (assetCount > 0) {
      findings.add(ImportFinding(
        '随身资源 $assetCount 个',
        'CHARX 包里的图片等资源，本轮只取头像一张，其余不导入。',
      ));
    }

    // 扩展与未知字段：只读列出，让用户知道哪些内容不会被用到。
    final extensions = data['extensions'];
    if (extensions is Map) {
      final names = extensions.keys.map((k) => k.toString()).toList()..sort();
      final unsupported =
          names.where((k) => unsupportedExtensions.contains(k)).toList();
      if (unsupported.isNotEmpty) {
        findings.add(ImportFinding(
          '不支持的扩展',
          '${unsupported.join('、')}：本 App 不执行卡内脚本/变量系统，内容会原样保留但不生效。',
          isWarning: true,
        ));
      }
      final other = names.where((k) => !unsupportedExtensions.contains(k)).toList();
      if (other.isNotEmpty) {
        findings.add(ImportFinding(
          '其它扩展字段（只读）',
          other.join('、'),
        ));
      }
    }

    final unknown = data.keys
        .map((k) => k.toString())
        .where((k) => !knownCardKeys.contains(k))
        .toList()
      ..sort();
    if (unknown.isNotEmpty) {
      findings.add(ImportFinding(
        '未识别的字段（只读）',
        '${unknown.take(8).join('、')}${unknown.length > 8 ? ' 等 ${unknown.length} 个' : ''}',
      ));
    }

    final fit = _fitFor(card, findings);
    return ImportReport(
      fit: fit,
      summary: _summaryFor(fit, card, findings),
      findings: findings,
    );
  }

  /// 聊天记录体检：条数、双方条数、空消息、时间跨度。
  static ImportReport forChat(
    List<ChatMessage> messages, {
    int? rawLineCount,
    int skippedLines = 0,
  }) {
    final findings = <ImportFinding>[];
    final userCount = messages.where((m) => m.role == 'user').length;
    final charCount = messages.length - userCount;
    if (messages.isEmpty) {
      return const ImportReport(
        fit: ImportFit.preserveOnly,
        summary: '这段记录里没有可导入的消息',
        findings: [
          ImportFinding('没有消息', '文件里所有行都为空或格式不认识。', isWarning: true),
        ],
      );
    }
    findings.add(ImportFinding(
      '共 ${messages.length} 条消息',
      '你 $userCount 条 · 角色 $charCount 条',
    ));
    if (skippedLines > 0) {
      findings.add(ImportFinding(
        '跳过 $skippedLines 行',
        '格式不认识或内容为空的行没有导入。',
        isWarning: true,
      ));
    }
    if (rawLineCount != null && rawLineCount > messages.length + skippedLines) {
      findings.add(ImportFinding(
        '文件有额外内容',
        '共 $rawLineCount 行，其中 ${rawLineCount - messages.length - skippedLines} 行不是消息（如元数据）。',
      ));
    }
    final unknownRole = messages.where(
      (m) => m.role != 'user' && m.role != 'assistant',
    );
    if (unknownRole.isNotEmpty) {
      findings.add(ImportFinding(
        '有 ${unknownRole.length} 条角色不明',
        '按角色消息导入。',
        isWarning: true,
      ));
    }
    final fit = messages.length < 3 ? ImportFit.partial : ImportFit.usable;
    return ImportReport(
      fit: fit,
      summary: fit == ImportFit.usable
          ? '可以直接接着这段记录继续聊'
          : '只有很少几条，导入后建议先补两句上下文',
      findings: findings,
    );
  }

  static ImportFit _fitFor(CharacterCard card, List<ImportFinding> findings) {
    final hasCore = card.description.trim().isNotEmpty;
    final hasOpening = card.firstMes.trim().isNotEmpty ||
        card.alternateGreetings.any((g) => g.trim().isNotEmpty);
    final warnings = findings.where((f) => f.isWarning).length;
    if (!hasCore && !hasOpening) return ImportFit.preserveOnly;
    if (!hasCore || !hasOpening || warnings >= 3) return ImportFit.partial;
    return ImportFit.usable;
  }

  static String _summaryFor(
    ImportFit fit,
    CharacterCard card,
    List<ImportFinding> findings,
  ) {
    final warns = findings.where((f) => f.isWarning).length;
    return switch (fit) {
      ImportFit.usable => warns == 0
          ? '字段齐全，可以完整使用'
          : '可以完整使用，有 $warns 处小提醒',
      ImportFit.partial => '可以用，但有 $warns 处会影响体验的地方',
      ImportFit.preserveOnly => '只能保存下来：缺少描述与开场白',
    };
  }
}
