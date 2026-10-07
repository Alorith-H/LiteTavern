import 'dart:convert';

import '../models/character_card.dart';
import '../models/world_info.dart';

/// AI 创建器：把模型返回的纯 JSON 文本解析成角色卡（v0.8.0）。
///
/// 容错顺序：
/// 1. 剥代码围栏（```json / ```）
/// 2. 取第一个 `{` 到最后一个 `}` 之间的整体 jsonDecode
/// 3. 兼容 `{"data": {...}}` 包裹（chara_card 规范形状）
/// 4. 解析失败 → 截断抢救：按字段正则从残片里捞出
///    name/description/personality/scenario/first_mes/mes_example，
///    捞到任一非空字段即视为成功（用户可在编辑页补齐）；
///    截断残片不抢救 character_book（世界级信息丢失可重新点生成）
///
/// 返回 null = 无法抢救（调用方 snackbar 提示，保留对话可再点生成）。
CharacterCard? parseGeneratedCard(String raw) {
  final stripped = _stripFences(raw.trim());
  if (stripped.isEmpty) return null;

  final start = stripped.indexOf('{');
  final end = stripped.lastIndexOf('}');
  if (start >= 0 && end > start) {
    final candidate = stripped.substring(start, end + 1);
    try {
      final decoded = jsonDecode(candidate);
      final card = _cardFromJson(decoded);
      if (card != null) return card;
    } catch (_) {
      // 落到截断抢救
    }
    final rescued = _rescue(candidate);
    if (rescued != null) return rescued;
  }
  // 连成对大括号都没有：整段当残片捞
  return _rescue(stripped);
}

/// 剥掉 markdown 代码围栏，只留里面的 JSON 文本。
String _stripFences(String s) {
  if (!s.contains('```')) return s;
  final inside = <String>[];
  var inFence = false;
  var sawFence = false;
  for (final line in s.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      sawFence = true;
      inFence = !inFence;
      continue;
    }
    if (inFence) inside.add(line);
  }
  if (sawFence) {
    final joined = inside.join('\n').trim();
    if (joined.isNotEmpty) return joined;
  }
  // 单行围栏等异常形态：粗暴去掉所有 ``` 再靠大括号截取
  return s.replaceAll('```', '').trim();
}

CharacterCard? _cardFromJson(Object? decoded) {
  if (decoded is! Map) return null;
  var data = decoded;
  final inner = decoded['data'];
  if (inner is Map) data = inner;
  final m = Map<String, dynamic>.from(data);
  if (m.isEmpty) return null;

  String str(String key) => m[key] is String ? m[key] as String : '';
  final name = str('name');
  final desc = str('description');
  final pers = str('personality');
  final scenario = str('scenario');
  final firstMes = str('first_mes');
  final mesExample = str('mes_example');
  if (name.isEmpty &&
      desc.isEmpty &&
      pers.isEmpty &&
      scenario.isEmpty &&
      firstMes.isEmpty &&
      mesExample.isEmpty) {
    return null; // 解出来是个空壳，不算成功
  }
  final altRaw = m['alternate_greetings'];
  return CharacterCard(
    name: name,
    description: desc,
    personality: pers,
    scenario: scenario,
    firstMes: firstMes,
    mesExample: mesExample,
    systemPrompt: str('system_prompt'),
    alternateGreetings: altRaw is List
        ? altRaw.whereType<String>().toList()
        : const [],
    tags: const [],
    creator: '',
    characterBook: _parseBook(m['character_book'], name),
  );
}

/// 解析卡内嵌世界书（v0.8.0 创建器要求 AI 输出 character_book）。
/// entries 为空视为 null（"没有可写的词条则返回 null，不许编造凑数"）；
/// 名字缺失时按角色名兜底。解析异常一律当 null，不阻塞出卡。
WorldInfo? _parseBook(Object? v, String charName) {
  if (v is! Map) return null;
  try {
    final m = Map<String, dynamic>.from(v);
    final raw = m['entries'];
    // chara_card 规范条目用 enabled，世界书模型用 disabled：入模前翻转对齐
    if (raw is List) {
      m['entries'] = [for (final e in raw) _flipEnabled(e)];
    } else if (raw is Map) {
      m['entries'] = {
        for (final e in raw.entries) e.key.toString(): _flipEnabled(e.value),
      };
    }
    final book = WorldInfo.fromJson(m);
    if (book.entries.isEmpty) return null;
    final name = book.name.trim().isEmpty
        ? (charName.trim().isEmpty ? '内嵌世界书' : '${charName.trim()}的世界书')
        : book.name;
    return WorldInfo(
      name: name,
      description: book.description,
      entries: book.entries,
    );
  } catch (_) {
    return null;
  }
}

/// 条目里的 `enabled`（chara_card 规范）翻成模型认识的 `disabled`；
/// 两者都给时以模型字段 `disabled` 为准；非 map 原样返回。
dynamic _flipEnabled(dynamic e) {
  if (e is! Map) return e;
  final m = Map<String, dynamic>.from(e);
  if (m.containsKey('enabled') && !m.containsKey('disabled')) {
    final en = m['enabled'];
    if (en is bool) m['disabled'] = !en;
  }
  return m;
}

/// 截断抢救：从（可能被截断的）JSON 残片按字段正则捞值。
///
/// 值允许含字面换行/未转义引号外的常规内容；
/// 捞到的字符串做 JSON 转义还原。
CharacterCard? _rescue(String fragment) {
  const fields = [
    'name',
    'description',
    'personality',
    'scenario',
    'first_mes',
    'mes_example',
    'system_prompt',
  ];
  final found = <String, String>{};
  for (final f in fields) {
    final re = RegExp('"$f"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"');
    final m = re.firstMatch(fragment);
    if (m == null) continue;
    final value = _unescape(m.group(1)!);
    if (value.isNotEmpty) found[f] = value;
  }
  if (found.isEmpty) return null;
  return _cardFromJson(found);
}

/// 还原 JSON 字符串转义（\n \t \" \\ \uXXXX，未知转义原样保留）。
String _unescape(String s) {
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != '\\' || i + 1 >= s.length) {
      buf.write(c);
      continue;
    }
    final n = s[++i];
    switch (n) {
      case 'n':
        buf.write('\n');
      case 't':
        buf.write('\t');
      case 'r':
        buf.write('\r');
      case '"':
        buf.write('"');
      case '\\':
        buf.write('\\');
      case '/':
        buf.write('/');
      case 'u':
        if (i + 4 < s.length) {
          final hex = s.substring(i + 1, i + 5);
          final cp = int.tryParse(hex, radix: 16);
          if (cp != null) {
            buf.write(String.fromCharCode(cp));
            i += 4;
            break;
          }
        }
        buf.write('u');
      default:
        buf.write(n);
    }
  }
  return buf.toString();
}
