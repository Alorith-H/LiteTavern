# 交接状态：v0.28.0 提示词检视升级（2026-11-27 更新）

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
> v0.27.0（世界书导出 / 命中测试 / 四范围绑定）。
>
> **本轮 v0.28.0 —— 提示词检视升级（评估清单 R5）**：
> 聊天菜单新增「提示词检视」：逐段 token、哪几段在缓存前缀内（可复用）、从哪一段开始重付；
> 摘要卡片给一句话结论；「可以省的地方」逐条指出时间宏 / 实时时钟 / 摘要改动 / 中间插入的系统注入；
> 「省钱排序建议」给出稳定优先的排列（系统提示 → 人设/作者注释 → 摘要 → 历史 → 本轮消息）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.28.0+29**，`lib/app_info.dart` `kAppVersion = '0.28.0'`。
- 本轮新增文件：
  - `lib/services/prompt_audit.dart`（纯逻辑，无 Flutter 依赖）：
    `PromptPartAudit`（index / role / label / tokens / change / insideCachePrefix / preview）、
    `PromptPartChange { same, changed, added, removed }`、
    `PromptAuditReport`（totalTokens / cacheableTokens / repayingTokens / firstChangeIndex /
    firstSend / cacheHitRatio / firstChangeLabel / summaryLine / suggestions）、
    `PromptAudit.analyze({current, previous, contextWindow})`、
    `PromptAudit.recommendedOrder(totalTokens)`；
  - `lib/screens/prompt_audit_screen.dart`：`PromptAuditScreen({current, previous, contextWindow})`，
    摘要卡片 + 省钱建议 + 可展开的逐段明细；右上「省钱排序建议」底部弹层；
  - `test/v28_test.dart`（16 例：首次发送 / 完全一致 / 末尾新增 / 中间改动与重付 token / 标签 /
    预览截断 / 五类省钱建议 / 推荐顺序 / 页面渲染与省钱排序弹层）。
- 本轮修改文件：
  - `lib/screens/chat_screen.dart`：新增 `_prevPrompt`（上一次发送的提示词，用于逐段比对），
    `_runOnce` 与 `_adoptJob` 赋值 `_lastPrompt` 前记录；菜单「查看发送内容」后新增「提示词检视」→
    `_openPromptAudit()`；未发送过时给提示「还没有发送过消息，先聊一句再来看」；
  - `lib/screens/api_config_screen.dart`：删除重复的「模型名」输入框（v0.20.0 引入的
    模型名 + 获取模型列表行已覆盖，旧的三件套里那一格是多余的，页面上会出现两个模型名）；
  - `CHANGELOG.md` v0.28.0 段；`docs/FEATURE_AUDIT.md` 第 45 行（发送内容检视）与 R5 行标 ✅。

## 提示词检视怎么读

1. 聊天页右上「⋮ → 提示词检视」（必须先发过至少一条消息）。
2. 顶部卡片：「共 N 段 · T token」+ 缓存条：
   - 第一次发送 → 「第一次发送：暂无缓存可复用」；
   - 与上次完全一致 → 「与上次完全一致：全部可复用（N token）」；
   - 其它 → 「缓存可复用 X / Y token（Z%）；从「标签」起改动，其后约 N token 会重付」。
3. 「可以省的地方」：时间宏（`{{time}}` 等）、实时时钟文字、摘要写在系统提示里、
   插在中间的系统注入段、段落数变化、接近窗口上限，各给一句怎么改。
4. 「逐段明细」：每段显示 token、变化徽章（未变 / 已变 / 新增 / 移除）、
   是否在缓存前缀内（⚡ 图标），展开看全文。
5. 右上「省钱排序建议」：越稳定越靠前、越常变越靠后，只给建议不会自动改设定。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（9.9s，含删除重复输入框后复跑） |
| `flutter test` | **+408 All tests passed!**（15s） |
| `flutter build apk --release` | 60.4MB，versionCode **29** / versionName **0.28.0** |
| 模拟器安装 | `emulator-5556` Success（0.28.0 / code 29） |
| 菜单入口点验 | 聊天「⋮」出现「提示词检视 · 逐段 token、缓存能复用到哪、哪里在浪费」 |
| 首次发送点验 | 接本机 mock 接口发一句 → 页面「共 2 段 · 87 token / 第一次发送：暂无缓存可复用」，逐段标「新增」（`build/v280_audit1.png`） |
| 第二次发送点验 | 再发一句 → 「前 75% 可复用，变动从「历史 · 角色回复 #2」开始」，系统提示段标「未变」（`build/v280_audit2.png`） |
| 省钱排序点验 | 右上图标弹出五段顺序 + 「当前发送约 116 token」说明（`build/v280_order.png`） |
| 模拟配置页点验 | 删除重复模型名后只剩一处「模型名 + 获取模型列表」，测试连接成功「模型：mock-model · 耗时 508 ms」（`build/v280_edit2.png`） |

## 真机 / 模拟器自测清单

1. 装 APK，配置一个接口（设置 → 模型服务 → 编辑 → 填地址 / Key / 模型名 → 测试连接 → 保存）；
2. 进一个角色，发两条消息；
3. 聊天「⋮ → 提示词检视」，确认：第一次是「暂无缓存可复用」，第二次出现「可复用 x%」；
4. 展开「逐段明细」，确认系统提示段有 ⚡（在缓存前缀内）、「本轮新消息」在断点之后；
5. 点右上「省钱排序建议」，确认五段顺序与说明。

离线自测小技巧：本机跑 `python build/mock_llm.py`（监听 8765，返回固定回复 + /v1/models），
模拟器里接口地址填 `http://10.0.2.2:8765/v1`、Key 随便填、模型 `mock-model`，
并在「聊天与上下文」关掉「流式传输」（mock 不支持 SSE）。

## 已知边界

- `_prevPrompt` 只在当前页面生命周期内有效：退出聊天页再进来，第一次打开检视会按「暂无上次记录」显示；
- token 是本地估算（`estimateTokens`），与供应商计数可能有偏差；
- 缓存断点按「从头连续相同的段」计算，供应商实际缓存粒度（如 128 token 对齐）可能更粗；
- 「系统注入 #i」包含深度注入的世界书与聊天内作者注释，它们的插入位置由各自设置决定；
- 检视页只做提示，不会自动改作者注释 / 世界书位置；
- 省钱排序建议是通用建议，不保证所有供应商都按前缀缓存。

## 下一轮（评估清单 R6 起）

- R6：显示正则库（导入 ST 正则、作用域 / 深度、启用开关、替换前后对比）；
- R7：ST 预设兼容（导入 preset JSON、prompts / prompt_order 可视化编辑、每聊天预设覆盖）；
- R8：CHARX 导入、ST `.jsonl` 聊天导入、导入体检报告、变量状态只读展示。

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

- analyze：No issues found!（8.4s；删除重复模型名后 9.9s 复跑，仍无 issue）
- test：+408 All tests passed!（15s）
- build：60.4MB，versionCode 29 / versionName 0.28.0
- 装机：模拟器 `emulator-5556` Success（0.28.0 / code 29）
- 真机流程：用本机 mock 接口（`build/mock_llm.py`，`http://10.0.2.2:8765/v1`）发两条消息，
  提示词检视的首次发送 / 第二次可复用 75% / 省钱排序弹层均已点验通过
