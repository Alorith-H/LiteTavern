# 交接状态：v0.27.0 世界书补全（2026-11-27 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.x（市场筛选、用户侧建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.x（6 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话、市场 NSFW 开关）、
> v0.16.0（用户人设、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.x（输入栏辅助三选一、自动摘要后台静默 + token 说明、菜单可滚动、建议回复并行提速）、
> v0.19.0（翻译接入必应：Azure Key + 网页版兜底）、
> v0.20.0（模型配置与上下文改造：按模型自动、获取模型列表）、
> v0.21.x（设置页二级菜单、引导新建配置、气泡下模型名、上下文按接口自报）、
> v0.22.0（服务商改回 DeepSeek 第一、智谱只留一家、本地 LibreTranslate）、
> v0.23.0（应用内自动更新）、
> v0.24.0（消息操作三件套、对话内搜索、功能评估清单）、
> v0.25.0（分支树页、导出长图 / EPUB）、
> v0.26.0（整库备份与恢复 zip）。
>
> **本轮 v0.27.0 —— 世界书补全（评估清单 R4）**：
> 世界书整本导出 .json（SillyTavern 兼容、可直接分享）；
> 命中测试面板（输入一句话，逐条说明会激活 / 不会激活的原因，含位置与深度）；
> 四范围绑定（全局 / 人设 / 角色 / 这段聊天），任一范围开启即注入、互不覆盖。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.27.0+28**，`lib/app_info.dart` `kAppVersion = '0.27.0'`。
- 本轮新增文件：
  - `lib/services/world_book_files.dart`：`WorldBookFiles.buildJson(book)`（缩进 JSON）、
    `parseBytes(bytes, {fallbackName})`（兼容 `{entries:{...}}` 与裸条目写法，校验空文件 / 非 JSON / 无条目）、
    `safeName()`、`writeTempFile()`、`shareBook()`（写临时文件 → 系统分享 → 清理）；
  - `lib/screens/world_book_bindings_screen.dart`：`WorldBookBindingsScreen({initialScope, initialOwnerId})`，
    `SegmentedButton` 四范围 + 归属者选择弹层 + 逐本开关；全局范围写 `AppSettings.mountedWorldBookIds`，
    其它范围写 `worldbooks/mounts.json` 的作用域键；
  - `test/v27_test.dart`（11 例：导出→导入往返、裸条目、坏文件、safeName、mountKey、
    作用域读写与旧键兼容、effective 合并去重、命中测试三类原因、递归命中、绑定页空态）。
- 本轮修改文件：
  - `lib/services/world_info_engine.dart`：新增 `EntryInspection` 与
    `WorldInfoEngine.inspect({books, text, charName, userName, random})`（逐条原因 + 位置提示 + 递归轮），
    新增私有 `_checkEntry` / `_positionHint`；
  - `lib/services/storage.dart`：新增 `WorldBookScope`（global / character / chat / persona）与
    `worldBookMountKey`、`worldBookMountsForScope`、`saveWorldBookMountsForScope`、
    `removeWorldBookMountsForScope`、`effectiveWorldBookMounts({charId, convId, personaId})`；
    `_writeAllMounts` 现在会按需创建 `worldbooks/` 目录（修复「先绑定、后导入世界书」时报错）；
  - `lib/screens/world_book_entries_screen.dart`：右上「⋮」菜单新增「命中测试」「导出世界书」；
  - `lib/screens/settings_screen.dart`：世界书分节新增「世界书绑定」入口，点书名进入条目页；
  - `lib/screens/chat_screen.dart`：单聊 / 群聊的世界书加载改为 `effectiveWorldBookMounts`
    （全局 + 人设 + 角色 + 聊天合并）；聊天菜单新增「世界书绑定」，返回后自动重算；
  - `CHANGELOG.md` / `docs/FEATURE_AUDIT.md`（世界书行与 R4 标 ✅）。

## 世界书四范围怎么工作

1. 设置 → 世界书 →「世界书绑定」，选范围（全局 / 人设 / 角色 / 这段聊天）；
2. 选归属者（人设 / 角色 / 具体聊天；全局不用选），逐本开关；
3. 聊天组装提示词时按 全局 → 人设 → 角色 → 聊天 合并去重；
4. 同一本书任一范围开启即注入，关掉某个范围不会关掉其它范围里已开启的同一本；
5. 角色编辑器里的旧挂载（以裸 charId 为键）仍然兼容，会被当作「角色」范围读取。

## 命中测试怎么读

- 输入一段文字，列表里逐条显示：
  - 「关键词「x」命中，注入在提示词开头 / 按深度 N 注入对话 / 注入在角色设定之后」；
  - 「常驻条目（没有关键词，总是注入）」；
  - 「关键词未命中：…」「主关键词「x」命中，但次级关键词未命中：…」；
  - 「关键词命中，但概率（N%）这一次没通过」；
  - 「递归命中：由其它已激活条目的内容触发」；
  - 「已禁用，不会注入」。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（5.0s） |
| `flutter test` | **+392 All tests passed!**（10s） |
| `flutter build apk --release` | 60.2MB，versionCode **28** / versionName **0.27.0** |
| 模拟器安装 | `emulator-5556` Success（0.27.0 / code 28） |
| 命中测试真机（模拟器）点验 | 「我们走进酒馆坐下」→ 激活 2 / 4 条，原因逐条正确（截图 `build/v270_hittest2.png`） |
| 导出世界书点验 | 生成 `测试世界书_20261127_192643.json`，系统分享显示 `Sharing 1 file`（`build/v270_export.png`） |
| 四范围绑定点验 | 全局 / 角色 / 这段聊天 / 人设 四段切换正常，角色范围显示归属者与逐本开关（`build/v270_bindings.png`、`build/v270_binding_role.png`） |
| 导入世界书点验 | 从 Downloads 导入 4 条世界书成功并默认启用（`build/v270_imported.png`） |

## 真机 / 模拟器自测清单

1. 设置 → 世界书 →「导入世界书」，选一个 ST 格式 .json，确认列表出现新书；
2. 点书名进条目页 → 右上「⋮ → 命中测试」，输入一句含关键词的话，确认激活条数与原因；
3. 右上「⋮ → 导出世界书」，确认分享面板里出现 `.json`；
4. 设置 → 世界书 →「世界书绑定」，切到「角色」选一个角色、打开一本书；
5. 回到聊天（同一角色）→ 菜单「世界书绑定」应默认停在「这段聊天」，返回后发送一句含关键词的话，
   在「查看发送内容」里确认世界书内容被注入。

## 已知边界

- 合并语义是「并集」：任一范围开启即注入，无法用「某范围关闭」去覆盖另一个范围的开启；
- 命中测试只对单本世界书做静态匹配，不包含概率随机的多次模拟（每次运行可能不同）；
- 「这段聊天」绑定写在 `worldbooks/mounts.json`，删除会话时不会自动清理（无害，重名 id 概率低）；
- 群聊合并时按成员逐个取「角色」范围，成员各自的角色绑定都会生效；
- 世界书导出只含 `name / description / entries`，不含原文件里未知的扩展字段。

## 下一轮（评估清单 R5 起）

- R5：提示词检视升级（缓存断点标注 + 省钱排序）；
- R6：显示正则库（导入 ST 正则、作用域 / 深度、替换前后对比）；
- R7：ST 预设兼容（导入 preset JSON、prompts / prompt_order 可视化）；
- R8：CHARX 导入、ST `.jsonl` 聊天导入、导入体检报告。

## 环境命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
C:\flutter\bin\flutter.bat analyze
C:\flutter\bin\flutter.bat test
C:\flutter\bin\flutter.bat build apk --release
# 模拟器（真机不在手边时）
C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk
C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s emulator-5556 shell am start -n com.alorith.litetavern/.MainActivity
# 真机（USB）
C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s 19faf100 install -r build\app\outputs\flutter-apk\app-release.apk
```

## 本次运行记录

- analyze：No issues found!（5.0s）
- test：+392 All tests passed!（10s）
- build：60.2MB，versionCode 28 / versionName 0.27.0
- 装机：模拟器 `emulator-5556` Success（0.27.0 / code 28），命中测试 / 导出 / 四范围绑定 / 导入均已点验
