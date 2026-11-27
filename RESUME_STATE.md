# 交接状态：v0.26.0 整库备份与恢复（2026-11-27 更新）

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
> v0.25.0（分支树页、导出长图 / EPUB）。
>
> **本轮 v0.26.0 —— 整库备份与恢复（评估清单 R3）**：
> 设置 → 帮助与关于 →「备份与恢复」，一个 .zip 带走角色卡与头像、聊天记录、世界书、
> 群聊和全部设置（模型配置、生成预设、人设、翻译 Key、书签、聊天索引）；
> 恢复时先解包校验（格式 / 版本 / 路径安全），列出备份时间与条数，确认后才写回。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.26.0+27**，`lib/app_info.dart` `kAppVersion = '0.26.0'`。
- 本轮新增文件：
  - `lib/services/backup_service.dart`：`BackupManifest` / `BackupArchive` / `BackupException`；
    `createBackup({docs, prefs, appVersion, now})` 递归收集四个数据目录并打包 zip；
    `parseBackup(bytes)` 校验 `format=litetavern-backup`、`formatVersion<=1`、路径合法；
    `restoreBackup(archive, {docs, replacePrefs})` 写回并导入设置；`writeTempZip(...)`。
  - `lib/widgets/backup_sheet.dart`：`showBackupSheet(context)` 底部弹层（导出 / 恢复 / 安全说明），
    导出走 `BackupService.createBackup` + 系统分享，恢复走 FilePicker + 确认框 + 忙态提示。
  - `test/v26_test.dart`（13 例：打包与解析一致性、空目录、非 zip、缺清单、格式不对、版本过新、
    `../` 穿越、绝对路径、写回一致性、写盘前二次校验、prefs 导出/恢复、临时 zip 命名、弹层渲染）。
- 本轮修改文件：
  - `lib/services/storage.dart`：`Storage.docsDir` 访问器；`AppSettings.exportPrefs()` /
    `importPrefs(Map)`（只处理 bool/int/double/String/List<String>）。
  - `lib/screens/settings_screen.dart`：帮助子页新增「备份与恢复」行。
  - `docs/FEATURE_AUDIT.md`：数据行与 R3 标为 ✅。
  - `CHANGELOG.md`：新增 v0.26.0 段；版本号两处同步。

## 验证

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found（6.4s） |
| `flutter test` | **+381 All tests passed!**（新增 13 例） |
| `flutter build apk --release` | 60.1 MB，versionCode **27** / 0.26.0 |
| 装机（模拟器） | `emulator-5556 install -r` → Success（0.26.0 / code 27） |

## 模拟器端到端验证（导出 + 恢复都走了一遍）

1. 设置 → 帮助与关于 → 拉到底「备份与恢复」→ 弹层两个入口与安全说明正常。
2. 点「导出备份 (.zip)」→ 生成 `LiteTavern_backup_20261127_190202.zip` → 系统分享出现（Sharing 1 file）。
3. 用同一套 `BackupService` 生成一份样例备份（manifest + `files/characters/9999/card.json`，
   prefs 里 `user_name=恢复测试`）推到 `/sdcard/Download/`，点「从备份恢复」→ 系统文件选择器出现该 zip。
4. 选中后弹确认框：「备份时间：2026-11-27 19:03 / 来自版本：v0.26.0 / 包含：1 个文件、1 项设置」
   + 覆盖提示 → 点「恢复」。
5. 重启 App 后主页出现 **「恢复测试角色 / 从备份恢复进来的角色卡」** → 文件写回成功，设置项也已导入。

截图：`build\v260_home.png`、`build\v260_backup_sheet.png`、`build\v260_backup_share.png`、
`build\v260_picker.png`、`build\v260_restore_confirm.png`、`build\v260_after_restore.png`。

## 已知边界

- 恢复是「覆盖同名文件」，不会删除备份里没有的数据；想彻底重来请先清空数据/卸载重装。
- 备份含 API Key 等敏感设置，界面上已提示只保存到信任的地方；不加密。
- 恢复后需要重启 App 让内存里的设置（模型配置、主题等）全部生效，界面会提示。
- 大备份（几百 MB）打包时是同步读文件，期间显示「正在打包备份…」忙态；未做后台 isolate。
- 备份不包含：缓存（翻译缓存、市场译文缓存）、更新临时文件。

## 下一轮建议（详见 `docs/FEATURE_AUDIT.md` 第 3 节）

R4：世界书整本导入导出 + 命中测试 + 四范围绑定；
R5：显示正则库 + 提示词检视升级；
R6：ST 预设兼容（先只读解析）；
R7：CHARX / jsonl 导入 + 体检报告；R8：变量与状态只读 + 卡脚本安全提示。

## 环境命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release
# 真机（USB 或无线调试地址会变）
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe devices
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s <serial> install -r build\app\outputs\flutter-apk\app-release.apk
# 模拟器
& C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -port 5556
```

发 Release 时 APK 上传地址直接拼
`https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk`；
token 用 `git credential fill` 取；含中文的脚本保存为 UTF-8 并用 `pwsh -File` 执行。
提交一律使用仓库配置身份，**不要**再传 `-c user.name/-c user.email`。

## 本次运行记录

- `flutter analyze`：No issues found（6.4s）
- `flutter test`：+381 All tests passed!
- `flutter build apk --release`：60.1 MB，versionCode 27 / versionName 0.26.0
- 真机：不在线（未装机）
- 模拟器：Success（0.26.0 / code 27）；备份导出与恢复的完整链路已按上面 5 步点验通过
