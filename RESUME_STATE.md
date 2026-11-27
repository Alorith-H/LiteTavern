# 交接状态：v0.35.0 缓存命中与费用估算（2026-11-27 更新）

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
> v0.34.0（每聊天生成参数覆盖：6 个采样键）。
>
> **本轮 v0.35.0 —— 评估清单「用量统计里的缓存命中与价格估算」**：
> 1. **缓存命中估算**：每次发送前，用「上一次实际发出去的提示词」与这一次逐段比，
>    算出从头连续未变的段有多少 token 可以命中供应商的前缀缓存，记到这条回复上
>    （`ChatMessage.cachedPromptTokens`）；旧数据没有这个字段时按 0 处理。
> 2. **统计页展示**：聊天页 ⋮ →「聊天统计」新增「缓存命中 N（x%）」行；
>    在 设置 → 聊天与上下文 → 用量与费用 填过单价后，还会显示「预计花费」「缓存省下」
>    和单价说明小字；没填单价时给一句「想估算费用？去 设置 → 聊天与上下文 → 用量与费用 填单价。」
> 3. **费用估算**：单价按「每 100 万 token」填输入 / 输出 /（可选）缓存命中价，缓存价留空
>    就用输入价；金额用 `formatMoney`（0 → `0`，< 0.0001 → `<0.0001`，< 0.01 → 4 位，其余 2 位）。
> 4. **边界**：这是**估算**，缓存命中按前缀长度推，不等同于供应商最终账单；不改动请求内容；
>    只有记录了 usage 的回复才参与统计。
>
## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.35.0+36**，`lib/app_info.dart` `kAppVersion = '0.35.0'`。
- 本轮新增文件：
  - `lib/services/usage_cost.dart`（纯 Dart，无 Flutter 依赖）：
    - `TokenPrice{inputPerMillion, outputPerMillion, cachedInputPerMillion}`：
      `free`、`configured`（输入或输出 > 0）、`effectiveCachedPrice`（缓存价 > 0 用它，否则用输入价）；
    - `UsageCost{inputTokens, outputTokens, cachedInputTokens, price}`：
      `uncachedInputTokens`、`cacheHitRatio`（0–1，clamp）、`total`、`cacheSavings`（≥0）、`merge`；
    - 顶层 `formatMoney(double)`。
  - `test/v35_test.dart`：14 例（TokenPrice 3、UsageCost 5、formatMoney 1、设置与消息 3、
    设置页 widget 2）。
- 本轮修改：
  - `lib/services/storage.dart`：新增 `priceInputPerMillion` / `priceOutputPerMillion` /
    `priceCachedPerMillion`（prefs 键 `price_input_per_million` / `price_output_per_million` /
    `price_cached_per_million`，double，默认 0）。
  - `lib/models/chat_message.dart`：新增 `cachedPromptTokens`（int?，v0.35.0），
    `fromJson` / `toJson`（非空才写）/ `copyWith` 都处理；旧数据为 null。
  - `lib/screens/chat_screen.dart`：新增 `_lastCachedEstimate`，在 `_runOnce` 里用
    `PromptAudit.analyze(current: toSend, previous: _prevPrompt).cacheableTokens` 估算；
    `_applyTokens` 把估算值累加到 `cachedPromptTokens`（clamp 到 promptTokens）；
    `_showChatStats` 重写为可滚动弹窗，新增缓存命中、预计花费、缓存省下与单价说明。
  - `lib/screens/settings_screen.dart`：「自动摘要怎么工作」之后新增「用量与费用」行
    （副标题 `_priceSummary()`），弹窗改成自持控制器的 `_PriceDialog`（避免关闭动画期间
    `TextEditingController used after dispose`），保存后写三个 AppSettings 并刷新副标题。
  - `CHANGELOG.md`（v0.35.0 段）、`docs/FEATURE_AUDIT.md`（缓存命中/费用估算行 ✅）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（8.5s，含 pub get） |
| `flutter test` | **+511 All tests passed!**（14s） |
| `flutter build apk --release` | **61.0MB**，versionCode **36** / versionName **0.35.0** |
| 模拟器装机 | `adb -s emulator-5556 install -r` → Success（code 36） |
| 模拟器点验 | 设置 → 聊天与上下文 → 用量与费用填 0.28 / 0.42 / 0.028，副标题变「输入 0.28/M · 输出 0.42/M」；聊天 ⋮ → 聊天统计显示「缓存命中 193（9%）」「预计花费 0.0006 元」「缓存省下 <0.0001 元」+ 单价说明；截图 `build/v350_price_dialog.png`、`v350_stats3.png` |
| 顺手验证 | 显示正则（v0.29.0）在真机聊天气泡上生效：`酒馆` → `酒馆🏮`，原文未改（`build/v350_chat1.png`） |

## 已知边界

- 缓存命中是**估算**：按「上一份提示词的前缀」推算，供应商实际计费口径可能不同；
  只统计记录了 usage 的回复；旧消息没有 `cachedPromptTokens` 时不参与。
- 费用估算需要用户自己填单价（每 100 万 token），默认 0 → 只显示 token；
  没有按模型自动带价格（各家价格变动频繁，不做内置表）。
- 缓存价留空时按输入价算，此时「缓存省下」为 0，这是预期行为。
- 其它沿用 v0.34.0 的边界（每聊天覆盖只 6 键；群聊各自独立；ST 兼容模式是叠加不是替换；
  变量只读不写回；卡内脚本永不执行）。

## 环境与常用命令

```powershell
# Flutter（不在 PATH）
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

# 模拟器（真机不在手边时）
C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio `
  -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556
adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

评估清单里剩下的都是「明确暂缓」或依赖外部服务的项（`docs/FEATURE_AUDIT.md`）：

- **群聊主持**（发言名单 / 顺序 / 让大家接着说）——纯本地，可做。
- 卡内脚本执行沙箱、HTML 组件 / 整页画布、Live2D / 立绘 / 舞台背景——明确不做或依赖重。
- TTS 朗读 / 语音输入、图像生成、向量长期记忆、Web 搜索、斜杠命令 / STscript——依赖外部服务，暂缓。

## 本次运行记录（2026-11-27）

- analyze：No issues（8.5s）
- test：+511 全过
- build：61.0MB，versionCode 36 / 0.35.0
- 模拟器：`emulator-5556` 装机 Success，点验费用弹窗与统计页
- 未真机：真机不在手边，按计划走模拟器 + mock 服务
