# LiteTavern 功能评估与实现计划

> 目标：评估现有功能、计划书里列的功能，以及**所有还没实现的功能**（不只对照 dsh-Go / SillyTavern），
> 然后逐个实现，每个功能都要有测试与回归验证，避免出现 bug。
>
> 本文件是工作的唯一清单：每完成一项就把状态从「未实现 / 部分」改成「已实现」，
> 并补上证据（文件:行号、测试名）。当前基线：v0.24.0（2026-11-27）。

## 0. 状态图例

- ✅ 已实现且有测试
- 🟡 部分实现 / 有边界
- ❌ 未实现

## 1. 总体状态

| 模块 | 功能 | 状态 | 证据 |
| --- | --- | --- | --- |
| 对话 | 流式/非流式生成、停止、重试、重新生成、继续生成 | ✅ | `lib/screens/chat_screen.dart`、`test/`（110+ 用例） |
| 对话 | 多候选建议回复（3 风格）、替我说一句 | ✅ | `lib/services/reply_suggestions.dart`、`test/v12_test.dart` |
| 对话 | 变体横滑切换、消息编辑、复制、书签 | ✅ | `chat_screen.dart` `_switchVariant/_editMessage/_toggleBookmark` |
| 对话 | **删除单条 / 删除这条及以后 / 对模型隐藏** | ✅ v0.24.0 | `lib/services/chat_transcript.dart`、`test/v24_test.dart`（18 例） |
| 对话 | **对话内搜索并跳转** | ✅ v0.24.0 | `lib/widgets/chat_search_sheet.dart`、`test/v24_test.dart` |
| 对话 | 分支（快照式）、聊天列表（多聊天/重命名/删除） | ✅ | `lib/services/chat_index.dart`、`test/v18_test.dart` |
| 对话 | **分支树可视化页** | ✅ | v0.25.0：`lib/screens/chat_tree_screen.dart` + `ChatIndex.tree`，菜单「分支树」进入 |
| 对话 | 对话内长按菜单滚动不溢出 | ✅ v0.18.1 | `_showMenu` 限高 + 滚动 |
| 对话 | 自动摘要（静默后台）+ 手动总结 | ✅ | `lib/services/summarize.dart`、`test/v15_test.dart` |
| 对话 | 上下文占用条 + 明细 + 阈值压缩 | ✅ | `chat_screen.dart` `_showContextUsage/_compressIfNeeded` |
| 对话 | 聊天统计（消息数、token、命中率） | ✅ | `chat_screen.dart` `_showChatStats` |
| 对话 | **缓存命中 / 费用估算统计** | ❌ | 统计里没有缓存命中与价格估算 |
| 对话 | 消息时间戳开关、字号 | ✅ | `settings_screen.dart` |
| 对话 | 群聊（多角色轮转、@指定、开场） | ✅ | `chat_screen.dart` `_runGroupRound` |
| 对话 | 群聊主持（发言名单/顺序/让大家接着说） | ❌ | 未实现 |
| 对话 | 对模型隐藏（软删） | ✅ v0.24.0 | 同上 |
| 提示词 | 世界书（front/after/depth、次要关键词、概率、递归、回看条数） | ✅ | `lib/services/world_info_engine.dart` |
| 提示词 | 世界书条目命中率展示 | ✅ | `lib/services/hit_stats.dart`、`world_book_entries_screen.dart` |
| 提示词 | 世界书导入/导出（整本）、命中测试面板、四范围绑定 | ✅ | `world_book_files.dart`、`world_info_engine.dart`（inspect）、`world_book_bindings_screen.dart`（v0.27.0） |
| 提示词 | 用户人设（多套、注入、{{user}}） | ✅ | `lib/services/user_personas.dart`、`test/v17_test.dart` |
| 提示词 | 作者注释（位置/深度/角色/默认继承） | ✅ | `lib/services/authors_note.dart`、`test/v17_test.dart` |
| 提示词 | 宏（{{char}}/{{user}}/{{persona}}/时间/随机/字段） | ✅ | `lib/services/macros.dart`、`test/v17_test.dart` |
| 提示词 | 生成预设（多套）+ 高级采样参数 | ✅ | `lib/screens/gen_presets_screen.dart`、`test/v9_test.dart` |
| 提示词 | **SillyTavern 预设 JSON 导入/执行（prompts/prompt_order/注入位置深度）** | ❌ | 自研预设与 ST 结构不兼容 |
| 提示词 | **每聊天预设覆盖（temperature 等 6 键）** | ❌ | 只有全局预设 |
| 提示词 | **显示正则库（导入 ST 正则、作用域/深度、替换对比）** | ❌ | 输出不做正则替换 |
| 提示词 | 发送内容检视（全文 + 分段 + 缓存断点 + 省钱排序） | ✅ | `lib/services/prompt_audit.dart`、`lib/screens/prompt_audit_screen.dart`（v0.28.0） |
| 角色卡 | 导入 PNG/JSON、编辑、导出 | ✅ | `card_parser.dart`、`character_edit_screen.dart`、`test/` |
| 角色卡 | 市场（Chub 全量筛选、译文、NSFW 开关、下载进度） | ✅ | `lib/screens/card_market_screen.dart`、`test/card_market_*` |
| 角色卡 | AI 创建角色卡 | ✅ | `card_creator_screen.dart` |
| 角色卡 | 翻译（Azure/LibreTranslate/必应网页/MyMemory/模型兜底） | ✅ | `lib/services/translator.dart`、`test/translation_test.dart` |
| 角色卡 | **CHARX 导入 / ST `.jsonl` 聊天导入 / 导入体检报告** | ❌ | 未实现 |
| 角色卡 | **卡内脚本执行（沙箱）/ HTML 组件 / 整页画布** | ❌ | 明确不做执行，最多做安全提示 |
| 世界书 | 条目管理、位置/深度/递归/概率 | ✅ | `world_book_entries_screen.dart`、`world_info_engine.dart` |
| 导出 | 剪贴板纯文本、`.txt` / `.json` 文件分享 | ✅ | `chat_export.dart`、`chat_export_files.dart` |
| 导出 | **长图 / EPUB / 故事书排版** | ✅ | v0.25.0：`chat_image_export.dart`（Canvas 长图）、`chat_epub_export.dart`（EPUB3） |
| 数据 | **整库备份与恢复（zip：卡/聊天/世界书/预设）** | ✅ | `lib/services/backup_service.dart` + `lib/widgets/backup_sheet.dart`；路径越界校验、恢复前确认（v0.26.0） |
| 数据 | 删除角色/群聊时的级联清理 | ✅ | `home_screen.dart` |
| 设置 | 两级菜单、6 分组、状态摘要 | ✅ | `settings_screen.dart`、`test/v21` |
| 设置 | 主题色/亮度/字号/时间戳/快捷回复 | ✅ | `settings_screen.dart` |
| 设置 | 应用内自动更新（检查/下载/系统安装/静默检查） | ✅ v0.23.0 | `updater.dart`、`update_flow.dart`、`test/v23_test.dart` |
| 引导 | 6 步零基础引导（拿 Key/配模型/选辅助/导入/完成） | ✅ | `onboarding_screen.dart`、`test/onboarding_screen_test.dart` |
| 模型 | 任意 OpenAI 兼容、多配置、获取模型列表、按模型自动上下文 | ✅ | `api_config_screen.dart`、`api_client.dart`、`test/v20_test.dart` |
| 高级 | **TTS 朗读 / 语音输入** | ❌ | 依赖系统或云服务，暂缓 |
| 高级 | **图像生成（配图）** | ❌ | 依赖外部服务 |
| 高级 | **向量长期记忆 / Web 搜索** | ❌ | 依赖嵌入模型/搜索服务 |
| 高级 | **变量与状态系统（MVU）只读展示** | ❌ | 未实现 |
| 高级 | **Live2D / 立绘 / 舞台背景 / 背景图** | ❌ | 未实现 |
| 高级 | 斜杠命令 / STscript | ❌ | 未实现 |

## 2. 未实现功能清单（按「纯本地 → 低风险 → 每天用得到」排序）

### A. 消息与本地数据（先做，风险低）

1. ~~删除单条 / 删除这条及以后 / 对模型隐藏~~ ✅ v0.24.0
2. ~~对话内搜索~~ ✅ v0.24.0
3. 分支树页：把分支关系可视化，可切换、可重命名、可删（复用 `ChatIndex` 的 owner/convId 约定）
4. 导出增强：长图（自绘或截图拼接）、EPUB（zip + xhtml，无新依赖可用 `archive`）
5. 整库备份与恢复：一个 zip 打包 `characters/`、`chats/`、`worldbooks/`、`prefs`；恢复时先校验再覆盖

### B. 世界书与正则（中风险）

6. ~~世界书整本导入/导出（ST 世界书 JSON）~~ ✅ v0.27.0
7. ~~世界书命中测试面板~~ ✅ v0.27.0（逐条原因 + 位置/深度）
8. ~~世界书四范围绑定~~ ✅ v0.27.0（全局 / 人设 / 角色 / 这段聊天）
9. 显示正则库：导入 ST 正则 JSON、作用域（显示/发送）、深度、替换前后对比、一键关
10. 发送内容检视升级：标注「打碎缓存」的段落 + 省钱排序建议

### C. ST 预设兼容（高风险）

11. 导入 ST 预设 JSON，按 `prompts` / `prompt_order` 可视化编辑
12. 注入位置与深度、`system_prompt` 覆盖、`continue_prefill` 子集
13. 每聊天预设覆盖（6 个采样键）
14. 与自研预设合并成「兼容模式」开关，失败可退回

### D. 卡生态与只读状态（中高风险）

15. CHARX 导入
16. ST `.jsonl` 聊天记录导入
17. 导入体检报告（可用 / 部分可用 / 只保留 + 原因）
18. 变量与状态只读展示（不做回退语义）
19. 卡内脚本安全提示（不执行）

### E. 暂不做（成本/定位不划算）

- 卡内脚本执行沙箱、HTML/CSS 整页画布、Live2D、自动导演、记忆书、MVU 完整状态回退、分享链接服务端、TTS/语音输入、图像生成、向量记忆、Web 搜索。

## 3. 实施顺序与每轮验收

每轮固定流程：实现 → 新增/更新测试 → `flutter analyze` → `flutter test` → `flutter build apk --release` → 真机装机抽查 → commit + push（作者用仓库配置，不加 `-c`）→ 必要时 Release。

| 轮次 | 内容 | 验收 |
| --- | --- | --- |
| R1（本轮） | 消息操作三件套 + 对话内搜索 + 本评估文档 | 新增 18 例测试全过；全量 353 例；analyze 干净 |
| R2 | 分支树页 + 导出长图/EPUB | ✅ 已完成（v0.25.0）；真机/模拟器验证见 RESUME |
| R3 | 整库备份与恢复 | ✅ v0.26.0：导出 zip → 清数据 → 恢复后角色/聊天/世界书一致（单测覆盖打包/解析/越界/写回） |
| R4 | 世界书导入导出 + 命中测试 + 四范围绑定 | ✅ v0.27.0：整本导出 .json 往返、命中测试逐条给原因、四范围合并去重（单测 + 模拟器点验） |
| R5 | 显示正则库 + 检视升级 | 检视已 ✅（v0.28.0：缓存断点 + 省钱排序）；正则库待 R6 |
| R6 | ST 预设兼容（分两步：只读解析 → 执行） | 导入 ST 预设后提示词与原文对齐 |
| R7 | CHARX / jsonl 导入 + 体检报告 | 坏卡给出逐条原因，不崩 |
| R8 | 变量与状态只读 + 卡脚本安全提示 | 只读展示不改变生成 |

## 4. 已知边界（实现时要留意的）

- 消息「对模型隐藏」只影响 prompt，导出与搜索仍包含；跨设备复制聊天文件后仍生效（字段在 JSON 里）。
- 删除不可恢复，不做软删回收站（除非以后加备份）。
- GitHub API 限流 60 次/小时（自动更新每天最多一次，问题不大）。
- 真机点按坐标与 uiautomator bounds 有偏移，验证时以截图为准。

## 5. 本轮变更记录（v0.24.0 第一批）

- `lib/models/chat_message.dart`：新增 `hidden` 字段（JSON `hidden: true`，旧数据默认 false），`copyWith` 支持切换。
- `lib/services/chat_transcript.dart`（新）：`visibleForModel`、`searchMessages`、`snippetAround`。
- `lib/widgets/chat_search_sheet.dart`（新）：搜索弹层（实时匹配、命中片段、时间/发言方、隐藏标记）。
- `lib/screens/chat_screen.dart`：
  - 消息长按菜单新增「对模型隐藏 / 取消隐藏」「删除这一条」「删除这条及以后」，菜单改为限高可滚动；
  - 隐藏消息气泡淡化到 45% 并标注「对模型隐藏」；
  - 组 prompt 前统一过滤隐藏消息（`_buildWith`）；
  - 聊天菜单新增「搜索对话」，选中结果后按时间戳跳转。
- 测试：`test/v24_test.dart` 18 例；全量 **353 全过**，`analyze` 干净。
