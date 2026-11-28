# 交接状态：v0.40.1 二级菜单返回上一级 + 设置页重新分组（2026-11-28 更新）

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
> v0.39.0（菜单布局重做：统一零件、分组、图标）、
> v0.40.0（聊天菜单改为二级：一级只列六组）、
> v0.40.1（二级菜单返回上一级 + 设置页重新分组）。
>
> **本轮 v0.40.1 —— 菜单层级与设置分组**：
> 1. **二级菜单返回上一级**：`showGroupedSheetMenu` 改为自绘 `showGeneralDialog` + `PopScope`；
>    二级里按系统返回键、或点菜单外的空白处，都先回到一级（不关闭），一级再返回/点空白才关。
> 2. **设置页重新分组**：`SettingsSection` 改为
>    `model / chat / appearance / market / worldBooks / help`，标题为
>    **模型与生成 / 聊天与上下文 / 外观与显示 / 角色卡市场与翻译 / 世界书 / 帮助与关于**；
>    首页入口顺序与图标随分组走（`SettingsSection.icon`）。
> 3. **模型与生成**：原首页「模型服务」配置行 + 「生成参数」子页合成一页（`_modelChildren`），
>    首页只留一个入口，副标题为「配置名 · 模型 · t/p」（`_modelSummary()`）。
> 4. **显示项归入外观**：对话排版 / 聊天气泡字号 / 消息时间戳 / 显示快捷回复 / 快捷回复管理 /
>    显示正则，从「聊天与上下文」移到「外观与显示」顶部「排版与显示」；
>    其后是主题模式、主题色、自定义颜色。
> 5. **版本号规则**：只有布局与交互调整 → 版本记 **0.40.1**（补丁号 +1）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.40.1+42**，`lib/app_info.dart` `kAppVersion = '0.40.1'`。
- 本轮新增 / 修改：
  - `lib/widgets/sheet_menu.dart`：`showGroupedSheetMenu` 改为自绘对话框 + `PopScope`；
    新增 `_SheetGroupHeader`（返回箭头 + 组名）、`_SheetDragHandle`；`_back()` 负责逐级返回。
  - `lib/screens/settings_screen.dart`：枚举 / 标题 / 图标重排；新增 `_modelChildren`、
    `_modelSummary()`；删除无用的 `_generationSummary()`；显示项移入 `_appearanceChildren`；
    `_appearanceSummary()` 带上排版名。
  - `test/v40_test.dart`：改为 5 例（返回箭头回一级 / 点空白回一级 / 系统返回先回一级等）。
  - `test/v21_test.dart`、`test/v37_test.dart`、`test/v39_test.dart`：同步新分组与图标。
  - `CHANGELOG.md`（v0.40.1 段）、`docs/FEATURE_AUDIT.md`（第 7 节本轮变更记录）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（3.8s） |
| `flutter test` | **+559 All tests passed!**（12s） |
| `flutter build apk --release` | 见下方「本次运行记录」 |
| 回归 | 单人 / 群聊、导出、世界书、ST 兼容、备份、排版等原有测试全绿 |

## 已知边界

- 二级菜单是自绘 `showGeneralDialog`（不是 `showModalBottomSheet`），因此不能再用
  `showModalBottomSheet` 的 `showDragHandle`；拖动条由内部 `_SheetDragHandle` 画（仅装饰、不可拖）。
- 设置首页六个入口的副标题里，模型与生成只显示「配置名 · 模型 · t/p」，不显示上下文窗口；
  上下文窗口在子页与模型配置里。
- 其它沿用 v0.40.0 / v0.39.0 的边界（消息长按菜单在模拟器上无法注入长按；
  底部弹层条目多时依赖滚动；恢复是覆盖；费用是估算；ST 兼容是叠加；变量只读；卡内脚本不执行）。

## 环境与常用命令

```powershell
# Flutter（不在 PATH）
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

# 真机（无线调试，端口每次可能变化）
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe devices
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe connect <ip:port>
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s <ip:port> install -r build\app\outputs\flutter-apk\app-release.apk

# 模拟器（真机不在手边时；AVD 已建好）
C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio `
  -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556
adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 ✅ 已覆盖绝大部分本地功能，剩下的 ❌ 都是「明确不做 / 依赖外部服务」
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。

后续可做的小项：聊天统计按模型拆分、自动更新忽略版本、恢复前自动快照、
其余底部弹层（聊天列表 / 书签 / 导出格式 / 市场筛选 / 模型列表）也换成 `sheet_menu` 零件、
把「设置首页」也改成二级菜单风格（目前是长列表 + 分节标题）。

## 本次运行记录（2026-11-28，v0.40.1）

- `flutter analyze` → No issues found!（3.8s）
- `flutter test` → +559 All tests passed!（12s）
- `flutter build apk --release` → **61.1MB（64,056,935 字节）**，versionCode **42** / versionName **0.40.1**（Gradle 52.1s）
- 真机 `adb -s 192.168.0.102:37433 install -r` → **Success**（dumpsys：versionCode 42 / 0.40.1 / lastUpdateTime 2026-11-28 09:52:27，数据保留）
- 真机点验：
  - 设置首页 dump 确认新分组：模型与生成（`Deepseek · deepseek-flash · t0.8 · p1.0`）/ 聊天与上下文 / 外观与显示（`气泡排版 · 跟随系统 · 主题色 #9C27B0 · 字号 15sp`）/ 角色卡市场与翻译 / 世界书 / 帮助与关于（`版本 v0.40.1`），截图 `build/v401_settings.png`；
  - 聊天菜单一级只有六组与概括、无标题（`build/v401_menu1.png`）；
  - 点「生成」进二级（`build/v401_menu2.png`）后按**系统返回** → 回到一级（六组仍在，`build/v401_afterback.png`）；
  - 二级点空白 → 回一级；一级点空白 → 菜单关闭（断言：level2→level1 groups=3，再点 groups=0 且输入栏可见）。
