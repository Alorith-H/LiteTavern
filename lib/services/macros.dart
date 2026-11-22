import 'dart:math';

/// 宏替换（v0.16.0 扩充，对齐 SillyTavern 常用宏）。
///
/// 支持：
/// - `{{char}}` / `<BOT>` → 角色名；`{{user}}` → 用户名
/// - `{{persona}}` → 用户人设描述（未设置时回落用户名）
/// - `{{description}}` / `{{personality}}` / `{{scenario}}` → 角色卡字段
/// - `{{time}}` HH:mm、`{{date}}` yyyy-MM-dd、`{{weekday}}` 星期X、
///   `{{isotime}}` ISO8601
/// - `{{random::a::b::c}}`（也接受逗号分隔）随机取一个；`{{random}}` 0–99
/// - `{{pick::a::b}}` 随机取一个（语义同 random，SillyTavern 兼容写法）
/// - `{{newline}}` → 换行；`{{trim}}` → 去掉整段首尾空白与多余空行
/// - `{{// 注释}}` → 整段删除
/// - `<START>` → 空行分隔（示例对话里常见）
///
/// 未知宏保持原样，方便排查拼写。
String applyMacros(
  String text, {
  required String charName,
  required String userName,
  String? personaText,
  Map<String, String>? cardFields,
  DateTime? now,
  Random? random,
}) {
  if (text.isEmpty) return text;
  var r = text;

  // 1. 注释先删（避免注释里的 {{char}} 被替换后残留）
  r = r.replaceAll(RegExp(r'\{\{\s*//[^}]*\}\}'), '');

  // 2. 固定替换
  r = r.replaceAll('{{char}}', charName).replaceAll('<BOT>', charName);
  r = r.replaceAll('{{user}}', userName);
  final persona = (personaText ?? '').trim();
  r = r.replaceAll('{{persona}}', persona.isEmpty ? userName : persona);
  r = r.replaceAll('<START>', '\n\n');

  // 3. 角色卡字段
  final fields = cardFields ?? const <String, String>{};
  for (final key in const ['description', 'personality', 'scenario']) {
    final value = fields[key];
    if (value != null) r = r.replaceAll('{{$key}}', value);
  }

  // 4. 时间类
  final clock = now ?? DateTime.now();
  r = r.replaceAll('{{time}}', '${_p2(clock.hour)}:${_p2(clock.minute)}');
  r = r.replaceAll('{{date}}', '${clock.year}-${_p2(clock.month)}-${_p2(clock.day)}');
  r = r.replaceAll('{{weekday}}', _weekdayCn(clock.weekday));
  r = r.replaceAll('{{isotime}}', clock.toIso8601String());

  // 5. 随机 / 抽取
  r = _replaceRandom(r, random ?? Random());

  // 6. 换行与裁剪
  r = r.replaceAll('{{newline}}', '\n');
  if (r.contains('{{trim}}')) {
    r = r.replaceAll('{{trim}}', '');
    // 每行去首尾空格 + 整段去首尾空白 + 折叠 3 个以上空行
    r = r
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .trim()
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }
  return r;
}

/// `{{random::a::b}}` / `{{random:a,b}}` / `{{random}}` / `{{pick::…}}`
String _replaceRandom(String text, Random rng) {
  var r = text;
  // 双冒号写法：{{random::a::b}}、{{pick::a::b}}
  r = r.replaceAllMapped(
    RegExp(r'\{\{\s*(?:random|pick)\s*::\s*([^}]*)\}\}'),
    (m) => _pickOne(m.group(1) ?? '', rng),
  );
  // 逗号写法：{{random:a,b}}
  r = r.replaceAllMapped(
    RegExp(r'\{\{\s*random\s*:\s*([^}]*)\}\}'),
    (m) => _pickOne(m.group(1) ?? '', rng),
  );
  // 无参数：0–99
  r = r.replaceAllMapped(
      RegExp(r'\{\{\s*random\s*\}\}'), (_) => '${rng.nextInt(100)}');
  return r;
}

String _pickOne(String raw, Random rng) {
  final parts = raw
      .split(RegExp(r'::|,'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';
  return parts[rng.nextInt(parts.length)];
}

String _p2(int n) => n.toString().padLeft(2, '0');

String _weekdayCn(int weekday) => switch (weekday) {
      DateTime.monday => '星期一',
      DateTime.tuesday => '星期二',
      DateTime.wednesday => '星期三',
      DateTime.thursday => '星期四',
      DateTime.friday => '星期五',
      DateTime.saturday => '星期六',
      _ => '星期日',
    };
