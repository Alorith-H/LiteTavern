# LiteTavern 商用加固审查记录

> 目标：把「会让 App 崩溃、卡死、丢数据」的路径找出来并加防护，让版本达到可对外发布的商用标准。
> 本轮版本：v0.41.0（2026-11-28）。审查方式：静态扫描 + 逐文件读关键路径 + 单测 + 模拟器压测。

## 1. 崩溃与卡死风险清单

| 类别 | 风险点 | 现状 | 处理 |
| --- | --- | --- | --- |
| 数据读取 | 角色卡 / 会话 / 世界书挂载 JSON 损坏 | 已防护 | `storage.dart` 各处 `try/catch` + 类型判断，坏数据跳过或回落空；本轮复核确认 |
| 压缩包炸弹 | CHARX 导入 zip 条目数 / 解压体积 | **本轮修复** | `charx_importer.dart`：条目 ≤ 2000、单文件 ≤ 100MB、解压总量 ≤ 200MB |
| 压缩包炸弹 | 备份 zip 条目数 / 解压体积 | **本轮修复** | `backup_service.dart`：条目 ≤ 20000、单文件 ≤ 200MB、解压总量 ≤ 1GB（另含路径穿越校验） |
| 超大文件 | 聊天记录 `.jsonl` 导入 | **本轮修复** | `st_chat_importer.dart`：文件 ≤ 100MB、行数 ≤ 20 万、单行 ≤ 2MB（超长行计入「跳过」） |
| 超大文件 | 角色卡文件导入 | **本轮修复** | `home_screen.dart`：读入前先判断 ≤ 50MB，否则提示「文件太大」 |
| ReDoS / 卡死 | 显示正则 pattern 或消息过长 | **本轮修复** | `display_regex.dart`：pattern ≤ 1000 字符、单次处理文本 ≤ 20 万字符（超限原样返回）、单次导入 ≤ 200 条 |
| 超大响应 | 模型接口返回异常大内容 / 非 JSON | **本轮修复** | `api_client.dart`：整段响应 ≤ 8MB、流式累积 ≤ 200 万字符（超限中断并给中文提示）、错误页最多读 64KB、非 JSON 给友好错误 |
| 崩溃无痕迹 | 未捕获异常没有记录 | **本轮修复** | 新增 `app_log.dart`（环形日志，内存 300 行 / 文件 256KB）+ `main.dart` 注册 `FlutterError.onError` 与 `PlatformDispatcher.onError`；设置 → 帮助与关于 → **诊断日志**（最近 150 条可复制） |
| 数值边界 | token 估算除零 / 负值 / 进度超 100% | 已防护 | `token_estimate`、`usage_cost`（clamp）、进度计算均做 `max(0, …)` 与 clamp |
| 异步安全 | `await` 之后 `setState` | 已防护（抽样） | 关键交互路径均判断 `mounted`；剩余风险见第 4 节 |
| 并发 | 生成中再次发送 / 取消竞态 | 已防护 | `_generating` 门禁 + `_genToken` 代次 + `ActiveGenerations` 单例按会话键管理 |

## 2. 本轮改动（v0.41.0）

- `lib/services/charx_importer.dart`：新增 `maxEntries` / `maxUncompressedBytes` / `maxSingleFileBytes` 与 `_guardArchive()`。
- `lib/services/backup_service.dart`：新增 `maxEntries` / `maxUncompressedBytes` / `maxSingleFileBytes`，恢复解析前统一校验。
- `lib/services/st_chat_importer.dart`：新增 `maxBytes` / `maxLines` / `maxLineChars`，超长行跳过。
- `lib/services/display_regex.dart`：`maxPatternLength` / `maxAppliedLength` / `maxImportCount`，异常正则不再参与替换。
- `lib/services/api_client.dart`：`maxResponseBytes` / `maxStreamChars` + `_readLimited()`，非 JSON 响应给中文提示。
- `lib/services/app_log.dart`（新增）：本地诊断日志，永不抛异常。
- `lib/main.dart`：注册全局异常处理，启动时记录版本号。
- `lib/screens/diagnostics_screen.dart`（新增）+ `settings_screen.dart`：设置 → 帮助与关于 → 诊断日志。
- `lib/screens/home_screen.dart`：单文件导入 50MB 上限。
- `test/v41_test.dart`（新增 12 例）：上限常量、CHARX 空包、jsonl 超行/超长行、正则超长 pattern/超长文本/导入条数、AppLog 环形保留与清空。

## 3. 验证流程（每次发布前必跑）

1. `flutter analyze` → 必须 `No issues found!`
2. `flutter test` → 必须全绿（本轮 572+）
3. `flutter build apk --release` → 检查 `output-metadata.json` 的 versionCode / versionName
4. 模拟器压测：`adb shell monkey -p com.alorith.litetavern -v 300`，随后 `adb logcat -b crash -d` 与 `adb logcat -d | findstr AndroidRuntime` 必须无 FATAL
5. 关键路径手测：导入角色卡（含 .charx）→ 聊天一轮 → 导出 → 备份/恢复 → 检查诊断日志为空

## 4. 已知残余风险（下一轮继续）

- 正则仍然只在「显示层」执行，超长文本会直接跳过（属预期降级）；如需彻底避免 ReDoS，后续可换用线性时间匹配库。
- 极少数第三方插件（file_picker / share_plus）在系统层崩溃无法被 Dart 捕获，只能通过降级与提示规避。
- 大文件聊天导出（长图）在低端机上可能耗时数秒，目前用 toast 提示，尚未做进度条。
- 备份包未加密：JSON 内有 API Key，分享备份需自行注意（README 与备份弹层已提示）。
