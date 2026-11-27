import '../models/character_card.dart';

/// 一条卡内脚本 / 富文本的安全提示（只读，不执行任何脚本）。
class ScriptFinding {
  final String title;
  final String detail;
  final bool isWarning;

  const ScriptFinding(this.title, this.detail, {this.isWarning = true});
}

/// 角色卡里与「脚本 / 动态内容」有关的东西，只识别、不执行。
class CardScriptScan {
  /// 卡扩展里出现的脚本类扩展键。
  final List<String> extensionKeys;

  /// 正文字段里疑似 HTML / 脚本注入的片段。
  final List<String> htmlWarnings;

  const CardScriptScan({
    this.extensionKeys = const [],
    this.htmlWarnings = const [],
  });

  static const CardScriptScan none = CardScriptScan();

  bool get hasScript => extensionKeys.isNotEmpty || htmlWarnings.isNotEmpty;

  String get summary {
    if (!hasScript) return '没有发现卡内脚本或动态内容';
    final parts = <String>[];
    if (extensionKeys.isNotEmpty) parts.add('扩展 ${extensionKeys.join('、')}');
    if (htmlWarnings.isNotEmpty) parts.add('正文里有 ${htmlWarnings.length} 处疑似脚本/iframe');
    return '${parts.join('；')}（不会执行）';
  }

  List<ScriptFinding> get findings {
    final out = <ScriptFinding>[];
    if (extensionKeys.isNotEmpty) {
      out.add(ScriptFinding(
        '卡内脚本扩展：${extensionKeys.join('、')}',
        '这些扩展在 SillyTavern 里可能由脚本驱动（自动更新变量、改界面等）。'
        '轻酒馆只读取、不运行它们，所以卡里的动态效果不会出现，也不会有安全风险。',
      ));
    }
    for (final w in htmlWarnings) {
      out.add(ScriptFinding(
        '正文里发现疑似 HTML / 脚本',
        '「$w」——不会被渲染或执行（聊天正文按纯文本/Markdown 显示）。',
      ));
    }
    return out;
  }
}

/// 识别角色卡里的脚本与动态内容（v0.33.0，只做提示）。
class CardScriptScanner {
  /// 与脚本 / 动态状态相关的扩展键（ST 生态常见命名）。
  static const List<String> scriptExtensions = [
    'regex_scripts',
    'tavern_helper',
    'st-script',
    'stscript',
    'mvu',
    'depth_prompt',
    'world',
    'character_book_scripts',
  ];

  /// 正文里需要提示的片段（不区分大小写）。
  static const List<String> _htmlMarkers = [
    '<script',
    '<iframe',
    'javascript:',
    'onerror=',
    'onload=',
    'onclick=',
  ];

  static CardScriptScan scan(CharacterCard card) {
    final extKeys = <String>[];
    for (final key in scriptExtensions) {
      final v = card.extensions[key];
      if (v == null) continue;
      if (v is Map && v.isEmpty) continue;
      if (v is List && v.isEmpty) continue;
      extKeys.add(key);
    }

    final warnings = <String>[];
    final fields = <String, String>{
      '角色描述': card.description,
      '开场白': card.firstMes,
      '示例对话': card.mesExample,
      '系统提示': card.systemPrompt,
      '场景': card.scenario,
    };
    for (final entry in fields.entries) {
      final lower = entry.value.toLowerCase();
      for (final marker in _htmlMarkers) {
        if (lower.contains(marker)) {
          final i = lower.indexOf(marker);
          final raw = entry.value.substring(
            i,
            (i + 40).clamp(0, entry.value.length),
          );
          final snippet = '${entry.key}：${raw.replaceAll(RegExp(r'\s+'), ' ')}';
          if (!warnings.contains(snippet)) warnings.add(snippet);
        }
      }
    }

    return CardScriptScan(extensionKeys: extKeys, htmlWarnings: warnings);
  }

  /// 多张卡（群聊）合并扫描。
  static CardScriptScan scanAll(List<CharacterCard> cards) {
    final keys = <String>{};
    final warnings = <String>[];
    for (final c in cards) {
      final scan = CardScriptScanner.scan(c);
      keys.addAll(scan.extensionKeys);
      for (final w in scan.htmlWarnings) {
        warnings.add('${c.name} · $w');
      }
    }
    return CardScriptScan(
      extensionKeys: keys.toList()..sort(),
      htmlWarnings: warnings,
    );
  }
}
