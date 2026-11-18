# 交接状态：v0.11.0 角色卡市场（2026-11-18 更新）

> v0.10.0：`task_spec_v9.txt` / `task_spec_v10.txt` 全部功能已落地，analyze 清零、
> 测试 114 条全过、release APK 构建成功；本轮修了 4 处收尾问题（commit `6d33486`）。
> v0.11.0（当前）：新增「角色卡市场」——App 内浏览 Chub.ai 公开角色卡并一键下载导入，
> 功能已实现，analyze 清零、测试 +124 全过、release APK 构建成功；**仍未做真机验证**
> （本机无 Android 设备/模拟器，见「待验证」）。

## v0.11.0 角色卡市场（本轮新增）

- 入口：主页右下 FAB / 空态按钮 → 底部弹窗「角色卡市场」→ `CardMarketScreen`
- 数据源：`Chub.ai`（`https://api.chub.ai/search`，免鉴权、默认只看 SFW、空关键词取热门），
  下载标准卡文件 `chara_card_v2.png`（PNG 内嵌 chara V2）→ 复用 `CardParser` 入库
- 新增文件：`lib/services/card_market.dart`（源抽象 + Chub 实现 + 客户端 + 错误映射）、
  `lib/services/card_importer.dart`（`importCardBytes` 统一入库：文件/链接/市场共用）、
  `lib/screens/card_market_screen.dart`（搜索防抖、两列网格、滚动加载、详情底部弹窗、
  下载并导入、空/错态、署名）、`test/card_market_test.dart`（10 例）
- 改动：`home_screen.dart`（市场入口 + `_importBytes` 改用 `importCardBytes`）、
  `pubspec.yaml:5` → `0.11.0+2`、`lib/app_info.dart` → `0.11.0`
- 更多来源调研与合规说明见 `docs/card_market_sources.md`

## 仓库状态

- 分支 `dev`，远端 `origin = https://github.com/Alorith-H/LiteTavern.git`（GCM 凭据可用）
- 基线 commit `6553062`（2026-10-09「feat: v0.10.0 …；110测试」），与 origin/dev 同步
- 本轮改动见 `git log -1` / `git status`（版本文案、摘要参数、删除会话清理、测试与文档）
- `pubspec.yaml:5` → `version: 0.11.0+2`；包名 `com.alorith.litetavern`
- 产物：`build\app\outputs\flutter-apk\app-release.apk`（57.6 MB，
  `output-metadata.json` versionCode 2 / versionName 0.11.0）

## 规格落地结论（对照两份 spec 逐条核过）

### v0.9.0 设置两级 + 高级采样 + 胶囊按钮 —— 21/21 完成
- 主设置页「生成参数」组：流式传输 Switch（默认开，`storage.dart:853-855`）+
  组末尾「高级设置」入口（`settings_screen.dart:370-390` → `advanced_settings_screen.dart`）
- 高级页字段：频率/存在惩罚 0–2 step.05、重复惩罚 1.0–2.0、top_k 0–200、min_p 0–0.5
  step.01、seed 空=随机、stop ≤4 行（`advanced_settings_screen.dart:110-222`）
- **默认值绝不出现在请求体**：`sampling_params.dart:48-59` 逐字段 `!= 默认才写`；
  `api_client.dart:12-32` 默认 body 与 v0.8（git `5c970ce`）逐字段一致
- 失败且带非默认高级字段 → 追加提示（`chat_screen.dart:2169-2177`、
  `card_creator_screen.dart:660-665`）
- 预设全字段持久化 + 旧 JSON 补默认 + 旧单套迁移（`storage.dart:437-524`、`:613-628`）
- 聊天/创建器/摘要统一走激活预设完整参数集（摘要本轮补齐 top_p，见下）
- 「单人|群聊」胶囊滑动 280ms easeOutCubic + 文字渐变
  （`widgets/segmented_toggle.dart:46-87`，home 实际使用 `home_screen.dart:411-419`），
  内容区淡入保留（`:377-390`）
- 不实现 DRY/XTC/Mirostat（高级页底部有说明）

### v0.10.0 退出不中断 —— 功能 13/13 满足
- `lib/services/active_generations.dart`：单例按 key（单聊=角色 id、群聊=`group_<id>`、
  创建器=`creator`）管理；dispose 只 detach 不 cancel
- 完成回调落库（`active_generations.dart:209-232`），重进接管 + 恢复停止按钮
  （`chat_screen.dart:312-372`、`card_creator_screen.dart:146-195`）
- 同 key 防重入（`:293` `if (_jobs.containsKey(key)) return null`）；停止走 manager.cancel
- 各 key 隔离、无并行发起入口；`test/v10_test.dart` 5 组用例覆盖
- 注：spec 里「追加 assistant」实际实现为**替换占位气泡**，语义等价（不产生重复消息）

## 本轮修复（4 项）

1. **关于页版本号写死 v0.8.0** → 新建 `lib/app_info.dart`（`kAppVersion = '0.10.0'`），
   `settings_screen.dart:927` 改为 `'版本 v$kAppVersion'`；新增
   `test/version_test.dart` 校验与 `pubspec.yaml` 一致（防再次漂移）
2. **摘要未走预设完整参数集（v0.9 唯一缺口）** → `api_client.dart` 抽出纯函数
   `buildSummaryRequestBody({model, system, user, temperature, topP, maxTokens, sampling})`，
   body 含 `top_p`（以前没有）；`summarize()` 增加 `double topP = 1.0` 参数；
   聊天摘要传 `AppSettings.temperature / topP`（不再固定 0.4）、创建器生成卡同传 topP
3. **删除角色/群聊时不注销后台任务** → `home_screen.dart` 删除前调用
   `ActiveGenerations.instance.remove(...)`，避免后台收尾把已删会话写回来
4. **测试补齐** → `test/v9_test.dart` 新增摘要参数组 3 例，加上版本防漂移 1 例

## 验证结果（本机实测）

| 项目 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **No issues found!**（28.2s） |
| 单元/组件测试 | `flutter test` | **+124 All tests passed!**（exit 0，v0.11.0 新增 10 例） |
| Release 构建 | `flutter build apk --release` | **成功**，57.5 MB，57.9s |
| 装机/真机 | — | **未执行**：无 Android 设备，见下 |

构建仅有两类非阻塞警告：`share_plus` 使用 KGP（未来 Flutter 版本会拒绝，届时需升级）；
NDK 版本不匹配（`android/app/build.gradle.kts:19` 写 27.0.12077973，插件建议
28.2.13676358，构建不受影响；要消除就改这行并确保 NDK 已装）。

## 待验证（有设备时按此清单做）

前置：`adb` 不在 PATH，`flutter devices` 只列 Windows/Chrome/Edge，
`flutter emulators` 无可用镜像 —— 需要真机开 USB 调试或先装模拟器镜像。

1. `adb install -r build\app\outputs\flutter-apk\app-release.apk`
2. 胶囊按钮：单人↔群聊切换，胶囊 250–300ms 平滑滑动、文字颜色渐变，内容区淡入
3. 高级设置：改 frequency_penalty / top_k / stop 后发消息，抓包确认字段进 body；
   全默认时 body 不含任何高级字段；失败时追加提示出现
4. 退出不中断：发消息→立刻返回主页→重进会话，应看到仍在生成 + 停止按钮可点；
   生成中杀进程→数据丢失（spec 允许）
5. 删除会话时若正在后台生成，删除后不应被写回
6. 角色卡市场：FAB → 角色卡市场 → 首屏应出热门卡（需联网）→ 搜索关键词 →
   点卡看详情 → 「下载并导入」→ 返回主页出现新角色；断开网络时应显示中文错误而不是崩溃

## 已知边界（有意保留，不阻塞发布）

- **S3 自动继续不跨页面**：离开页面后完成的消息会落库，但「自动继续/群聊成员轮转」
  的后续链条不续跑（v10 spec 只要求落库；`chat_screen.dart:360-369` 只收尾）
- **S4 创建器「生成角色卡」仍是页面私有请求**：生成卡中途退出页面会取消该请求
  （访谈主流程已接入 manager，不受影响）
- **S5/S6 纯 UI 细节**：预设名显示在分区标题下；top_k/stop 输入框超范围时存的是
  裁剪后的值、框内文本不回写（第 5 条 stop 静默丢弃）
- **B2/B3 低风险竞态**：停止后立即重生成时，旧任务收尾写盘可能与新任务交错
  （有 `chat_message.dart:113-120` 自愈）；后台落库只写 content/error，
  variants/token 记账依赖页面存活路径

## 环境

- Flutter 3.47.6 stable：`C:\flutter\bin\flutter.bat`（不在 PATH；`dart` 同样不在）
- 跑任何 flutter 命令前设：`$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`
- 机器上可能有用户自己的其他 claude 进程，杀进程前先按启动时间认准

## 历史归档（2026-10-07/08 的旧断点，已全部过期）

旧 `RESUME_STATE.md` 曾记录：mimo 网关对 claude-code 长请求连续 5 次挂起（进程活着、
30+ 分钟零改动），有效处置是杀进程重启。该问题属旧工具链，当前会话未复现；
v9「~90% / v10「~40%、「card_creator 未接入」「v10_test 未写」等描述均已被
commit `6553062` 与本轮验证推翻。
