# 交接状态：v0.23.0 应用内自动更新（2026-11-27 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.x（6 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话、市场 NSFW 开关）、
> v0.16.0（用户人设、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.x（输入栏辅助三选一、自动摘要后台静默 + token 说明、菜单可滚动、建议回复并行提速）、
> v0.19.0（翻译接入必应：Azure Key + 网页版兜底）、
> v0.20.0（模型配置与上下文改造：按模型自动、获取模型列表）、
> v0.21.x（设置页二级菜单、引导新建配置、气泡下模型名、上下文按接口自报）、
> v0.22.0（服务商改回 DeepSeek 第一、智谱只留一家、本地 LibreTranslate）。
>
> **本轮 v0.23.0 —— 应用内自动更新**：
> 设置里「检查更新」+ 启动时每天静默检查一次；发现新版可下载 APK（带进度）并交给系统安装器覆盖升级，
> 聊天记录与角色卡都保留。全程用 GitHub Releases，不用再手动去网页下载。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.23.0+24**，`lib/app_info.dart` `kAppVersion = '0.23.0'`。
- 本轮新增文件：
  - `lib/services/updater.dart`：`UpdateInfo`（version/tag/notes/apkUrl/apkSize/pageUrl/publishedAt、
    `hasApk`、`apkSizeLabel`）、`UpdateCheckException`、`formatBytes`、`normalizeVersion`、
    `compareVersions`（只比数字段，`0.23.0-beta` == `0.23.0`）、
    `UpdateService`（`latestReleaseUri`、`checkForUpdate({currentVersion})`、
    `static parseRelease(body, {currentVersion})`、`downloadApk(info, {dir, onProgress, isCancelled})`、
    `dispose`；`maxApkBytes = 300MB`）。
  - `lib/services/apk_installer.dart`：`ApkInstaller.install(File)` →
    平台通道 `litetavern/installer` 的 `installApk`；`ApkInstallException`。
  - `lib/widgets/update_flow.dart`：`checkUpdatesManually(context)`、
    `maybeAutoCheckUpdates(context)`（24 小时节流、静默失败）、
    `UpdateDialog`（检查中 / 已最新 / 失败可重试 / 发现新版 + 说明 + 体积 / 下载进度 / 打开安装界面；
    「稍后」写入 `AppSettings.skippedUpdateVersion`，同版本不再自动弹）。
  - `test/v23_test.dart`（20 例：版本比较、体积文案、Release 解析 6 例、检查网络 3 例、
    下载 3 例（进度/取消/无附件）、设置项 2 例、对话框 4 例）。
  - `android/app/src/main/res/xml/file_paths.xml`：FileProvider 暴露 `cache/updates/`。
- 本轮修改文件：
  - `lib/services/storage.dart`：`autoCheckUpdates`（`auto_check_updates`，默认 true）、
    `lastUpdateCheckMs`（`last_update_check_ms`）、`skippedUpdateVersion`（`skipped_update_version`）。
  - `lib/screens/settings_screen.dart`：帮助与关于页新增「检查更新」行 + 「启动时自动检查更新」开关；
    字段 `_autoCheckUpdates`。
  - `lib/screens/home_screen.dart`：`initState` 里 `addPostFrameCallback` →
    `maybeAutoCheckUpdates(context)`。
  - `android/app/src/main/kotlin/com/alorith/litetavern/MainActivity.kt`：`configureFlutterEngine`
    注册 `litetavern/installer`，用 `FileProvider.getUriForFile` + `ACTION_VIEW` 调系统安装器。
  - `android/app/src/main/AndroidManifest.xml`：`REQUEST_INSTALL_PACKAGES` 权限、
    `androidx.core.content.FileProvider`（authorities `${applicationId}.fileprovider`）、
    `queries` 增加 package-archive 的 VIEW intent。
  - `android/app/build.gradle.kts`：`dependencies { implementation("androidx.core:core:1.13.1") }`。

## 自动更新怎么工作

1. `GET https://api.github.com/repos/Alorith-H/LiteTavern/releases/latest`（20s 超时、UA LiteTavern）；
   draft / prerelease 跳过，`tag_name` 归一化后与 `kAppVersion` 比数字段，不更新则返回 null。
2. 有新版：取 `assets` 里名字以 `.apk` 结尾的附件（优先 `app-release.apk`），带上体积与下载地址。
3. 下载：流式写入 `getTemporaryDirectory()/updates/LiteTavern-<version>.apk`，
   每 2% / 256KB 回调一次进度，可中途取消（取消会删掉半成品），上限 300MB。
4. 安装：`FileProvider` 把缓存文件变成 `content://`，`Intent.ACTION_VIEW` +
   `application/vnd.android.package-archive` 交给系统安装器；用户在系统弹窗点「安装」即覆盖升级。
5. 自动检查：启动后（首页第一帧）若距上次检查 ≥24h 且开关开着，就静默查一次；
   失败不打扰，有新版且不等于「跳过的版本」才弹窗。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!**（3.8s） |
| `flutter test` | **+335 All tests passed!**（7s，其中 test/v23_test.dart 20 例） |
| `flutter build apk --release` | 59.3MB（Gradle 103.7s），versionCode **24** / versionName **0.23.0** |
| 装机 | 待设备连接后安装（见「本次运行记录」） |

## 真机自测清单（v0.23.0）

1. 覆盖安装新 APK 后打开应用 → 首页正常、角色与聊天记录都在。
2. 设置 → 帮助与关于 → 看到「检查更新（当前 v0.23.0）」与「启动时自动检查更新」开关（默认开）。
3. 点「检查更新」：若线上还没有更高版本 → 弹「已是最新版本」。
4. 下一个版本发布后（提高 versionCode/versionName 并发 Release）：
   启动应用会自动弹「发现新版本」；点「下载并安装」→ 进度条走完 → 系统安装界面点「安装」→ 覆盖升级成功。
5. 点「稍后」后同一版本不再自动提醒；手动「检查更新」仍能看到。

## 已知边界

- 更新源固定为 GitHub Releases（`Alorith-H/LiteTavern`）；国内网络可能较慢，失败只提示不阻断使用。
- 未接入应用商店，也没有增量更新：每次都是完整 APK（约 59–62MB）。
- Android 8+ 首次安装需要用户在系统弹窗里允许「安装未知应用（来自 LiteTavern）」；
  拒绝时对话框给出引导文案，不重试。
- API 未鉴权，GitHub 限流为每 IP 60 次/小时；只做一天一次检查，正常不会触发。
- 下载到缓存目录，安装完成后系统清理可能留下旧 APK；同名新版本会覆盖写入。
- 自动检查只记录「上次检查时间」，不做后台定时任务（进程不在就不检查）。
- 之前版本的既有边界继续有效（见下方「其它已知边界」）。

## 其它已知边界（沿用）

- 模型名取「发送那一刻的 model」；旧消息无 `model` 字段则不显示。
- 上下文长度「自动」是按模型名 / `/models` 自报推断；`/models` 不支持时给中文提示。
- 必应网页版接口按 IP 风控（`ShowCaptcha`）属正常，会自动换源。
- `assistMode` 默认 off；从旧版本升级时读 `auto_reply_candidates` 迁移一次。
- 自动摘要静默执行，会额外消耗一次模型调用（设置里已注明）。
- 引导页只填一部分也会新建配置；完全没填不会。
- 角色卡市场 NSFW 默认关；LibreTranslate 默认不启用（需填地址）。

## 环境与常用命令

- Flutter：`C:\flutter\bin\flutter.bat`（不在 PATH）；先设
  `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`。
- 构建：`flutter build apk --release` → `build\app\outputs\flutter-apk\app-release.apk`。
- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`；真机 23113RKC6C（Android 16，1440×3200）。
  USB 序列号 `19faf100`；无线调试地址会变（先 `adb devices`，必要时 `adb connect <ip>:<port>`）。
- 真机点按用**视觉坐标**（uiautomator bounds 常与视觉位置不符）。
- git 提交不要传 `-c user.name/-c user.email`（仓库配置已是 `Alorith-H <2835147611@qq.com>`）。
- 发 Release：`git tag -f vX.Y.Z` + push tag，再用 GitHub REST API 创建 release 并上传
  `app-release.apk` 附件（上传地址直接拼
  `https://uploads.github.com/repos/<owner>/<repo>/releases/<id>/assets?name=app-release.apk`）。

## 本次运行记录（v0.23.0）

- `flutter analyze`：No issues found!（3.8s）
- `flutter test`：+335 All tests passed!（7s）
- `flutter build apk --release`：59.3MB（Gradle 103.7s），versionCode **24** / versionName **0.23.0**
- 装机：`adb devices` 为空、`adb connect 192.168.0.102:42543` 报 10061（无线调试端口已变）→ **本轮未装机**。
  用户下次插 USB / 给新端口后，执行
  `adb -s <serial> install -r build\app\outputs\flutter-apk\app-release.apk` 即可；
  装好这一次之后，后续版本都可以用应用内「检查更新」自升级。
