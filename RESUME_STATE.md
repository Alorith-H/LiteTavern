# 交接状态：v0.39.0 菜单布局重做（2026-11-28 更新）

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
> v0.26.0（整库备份与恢复 zip）、
> v0.27.0（世界书导出 / 命中测试 / 四范围绑定）、
> v0.28.0（提示词检视升级：缓存断点 + 省钱排序）、
> v0.29.0（显示正则库：导入 ST 正则 / 作用域 / 试一下 / 只改显示）、
> v0.30.0（SillyTavern 预设只读解析）、
> v0.31.0（SillyTavern 兼容模式：预设提示词真实注入）、
> v0.32.0（CHARX 导入、`.jsonl` 聊天导入、导入体检报告）、
> v0.33.0（变量与状态只读、卡内脚本安全提示）、
> v0.34.0（每聊天生成参数覆盖：6 个采样键）、
> v0.35.0（聊天统计里的缓存命中与费用估算）、
> v0.36.0（群聊主持：发言名单与顺序、让大家接着说）、
> v0.37.0（对话排版：气泡 / 小说）、
> v0.38.0（备份恢复可选内容）、
> v0.39.0（菜单布局重做：统一零件、分组、图标）。
>
> **本轮 v0.39.0 —— 菜单布局重做**：
> 1. **统一零件**：新增 `lib/widgets/sheet_menu.dart`，提供 `SheetMenuTitle` /
>    `SheetMenuSection` / `SheetMenuItem`（支持 danger、禁用、trailing）/ `showSheetMenu`。
>    以后所有底部菜单都用这一套：标题 + 分组 + 图标 + 一行副标题。
> 2. **聊天菜单重做**：原来 20 项平铺 → 六组：生成 / 这段聊天 / 提示词与统计 /
>    导入与导出 / 角色 / 危险操作。菜单顶部显示「聊天菜单 · 当前：<会话名>」。
> 3. **消息长按菜单重做**：12 项平铺 → 四组：查看与修改 / 剧情 / 给模型 / 危险操作
>    （删除类用 error 色，生成或摘要进行中时禁用删除）。
> 4. **主页两处菜单**：角色长按加标题与「编辑 / 危险操作」分组；
>    导入弹层改「在线获取 / 从手机或链接 / 自己创建」三组，市场带「推荐」徽章，底部格式说明。
> 5. **设置首页**：六个二级入口加图标（tune / forum / storefront / menu_book / palette / help），
>    `_actionRow` 支持 leading 图标。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.39.0+40**，`lib/app_info.dart` `kAppVersion = '0.39.0'`。
- 本轮新增 / 修改：
  - `lib/widgets/sheet_menu.dart`（新）：菜单统一零件（标题 / 分组小标题 / 条目 / 弹层）。
  - `lib/screens/chat_screen.dart`：`_showMenu` 与 `_showMessageActions` 全量重写为分组菜单。
  - `lib/screens/home_screen.dart`：`_showActions` 与 `_showImportSheet` 重写为分组菜单。
  - `lib/screens/settings_screen.dart`：`_actionRow` 增 `leading` 图标参数；首页六个入口加图标。
  - `test/v39_test.dart`（新，7 例）：零件渲染 / 禁用 / danger 配色 / 弹层开合 / 设置首页图标。
  - `CHANGELOG.md`（v0.39.0 段）、`docs/FEATURE_AUDIT.md`（本轮变更记录）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（3.7s） |
| `flutter test` | **+554 All tests passed!**（15s，含新增 7 例） |
| `flutter build apk --release` | **61.1MB**，versionCode **40** / versionName **0.39.0** |
| 模拟器装机 | `adb -s emulator-5556 install -r` → Success（code 40 / 0.39.0） |
| 导入弹层点验 | dump 确认「导入角色卡 / 在线获取 / 角色卡市场·推荐 / 从手机或链接 / 从文件导入 / 从链接下载 / 自己创建 / AI 创建角色卡」（截图 `build/v390_import.png`） |
| 设置首页点验 | 六行二级入口带图标 + 「帮助与关于 · 版本 v0.39.0」（截图 `build/v390_settings.png`） |
| 聊天菜单点验 | dump 确认标题「聊天菜单 · 当前：恢复测试角色」与「生成 / 这段聊天 / 聊天列表 / 分支树 / 搜索对话 / 书签 / 作者注释 / 这段聊天的生成参数」（`build/v390_chatmenu.png`）；滚动后「提示词与统计 / 查看发送内容 / 提示词检视 / 上下文占用 / 聊天统计 / 导入与导出 / 复制对话」（`build/v390_chatmenu2.png`） |
| 对话排版切换 | 设置 → 聊天与上下文 → 显示 → 对话排版 → 气泡（由小说切回），气泡恢复左右分栏（`build/v390_layout_sheet.png`） |
| 回归 | 单人 / 群聊、导出、世界书、ST 兼容、备份等原有测试全绿 |

## 已知边界

- 消息长按菜单在**模拟器**上无法用 `adb shell input` 注入长按（swipe 零位移、motionevent 分段都无效，
  真机 v0.24 时可验证）；该菜单内容改动由 `test/v39_test.dart` 与静态检查覆盖。
- 菜单仍是底部弹层（不用抽屉 / 全屏页），条目多时依赖滚动；分组标题不吸顶。
- 其它沿用 v0.38.0 的边界（恢复是覆盖、设置项整类、需重启；排版只管显示；
  发言名单按群保存；接着说不计命中率；费用是估算；每聊天覆盖只 6 键；
  ST 兼容模式是叠加不是替换；变量只读；卡内脚本不执行）。

## 环境与常用命令

```powershell
# Flutter（不在 PATH）
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

# 模拟器（真机不在手边时；AVD 已建好）
C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio `
  -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556
adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk

# 模拟器是 google_apis（可 root）：核对应用私有目录
adb -s emulator-5556 root
adb -s emulator-5556 shell "ls -R /data/data/com.alorith.litetavern/app_flutter"

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 ✅ 已覆盖绝大部分本地功能，剩下的 ❌ 都是「明确不做 / 依赖外部服务」
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。

后续可做的小项：聊天统计按模型拆分、自动更新忽略版本、恢复前自动快照、
其余底部弹层（聊天列表 / 书签 / 导出格式 / 市场筛选 / 模型列表）也换成 `sheet_menu` 零件。

## 本次运行记录（2026-11-28）

- `flutter analyze` → No issues found!（3.7s）
- `flutter test` → +554 All tests passed!（15s）
- `flutter build apk --release` → 61.1MB，versionCode 40 / 0.39.0
- `adb -s emulator-5556 install -r` → Success（code 40 / 0.39.0）
- 模拟器点验：导入弹层分组、设置首页六图标、聊天菜单两组（含滚动）、对话排版切回气泡，截图见 `build/v390_*.png`
