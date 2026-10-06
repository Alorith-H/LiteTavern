/// 宏替换：所有卡片字段和世界书内容渲染时执行。
/// - `{{char}}` / `<BOT>` → 角色名
/// - `{{user}}` → 用户名
/// - `<START>` → 空行分隔（示例对话里常见）
String applyMacros(
  String text, {
  required String charName,
  required String userName,
}) {
  var r = text;
  r = r.replaceAll('{{char}}', charName).replaceAll('<BOT>', charName);
  r = r.replaceAll('{{user}}', userName);
  r = r.replaceAll('<START>', '\n\n');
  return r;
}
