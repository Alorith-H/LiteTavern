# 交接状态：v0.17.0 对话管理（多聊天 / 分支 / 书签）（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）、
> v0.16.0（用户人设 Persona、作者注释、宏增强、替我说一句、导出对话文件）。
>
> **本轮 v0.17.0**：对话管理三件套 ——
> ① **多聊天文件**（同一角色/群聊下多段互不干扰的聊天：新建/切换/重命名/删除）；
> ② **对话分支**（长按消息 → 从这里创建分支，复制到该条为止的历史）；
> ③ **消息书签**（长按消息收藏、书签列表一键跳转）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.17.0+15**，`lib/app_info.dart` `kAppVersion = '0.17.0'`。
- 新增文件：`lib/services/chat_index.dart`、`lib/services/bookmarks.dart`、`test/v18_test.dart`。
- 改造文件：`lib/screens/chat_screen.dart`、`lib/screens/home_screen.dart`、`lib/screens/storage.dart`（无）、
  `CHANGELOG.md`。

## 本轮变更（v0.17.0）

### 1. 多聊天文件

- `lib/services/chat_index.dart`：`ChatInfo{id,name,updatedAt,messageCount}` + `ChatIndex`
  （`ownerOf/load/save/ensure/find/touch/rename/remove/newId/nextName/sorted/resetForTest`）。
  索引存 prefs 键 `chat_index_<owner>`；owner = 角色 id 或 `group_<群id>`。
- 会话 key：旧会话沿用历史 id（单聊 = 角色 id、群聊 = `group_<群id>`）；
  新聊天 = `<owner>~<毫秒时间戳 36 进制>`，对应 `conversations/<id>.json`。
- `lib/screens/chat_screen.dart`：`ChatScreen` / `ChatScreen.group` 新增可选
  `convId` / `chatName`；`_convId` 优先用显式 id；`_ownerId`、`_chatTitle` 统一。
  老会话在加载时用 `ChatIndex.ensure` 补进索引（显示「（默认）」后缀）。
  `_save()` 落库后同步 `ChatIndex.touch`（条数 + 最近时间），失败不影响聊天。
- 聊天页标题可点（带 `expand_more` 图标）→ 底部聊天列表 `_ChatListSheet`：
  新建聊天（自动起名「新聊天 2」…）、切换（`pushReplacement`）、重命名、删除
  （不允许删当前那段、至少保留一段）；底部提示「每段聊天相互独立」。
- 删除角色 / 群聊时，`home_screen.dart` 会先按索引清理其名下所有分段聊天的会话文件、
  书签与后台任务，再删主存储。

### 2. 对话分支

- `_branchFrom(index)`：复制 `_messages.take(index+1)`（用 `toJson/fromJson` 深拷贝），
  写入新会话 + 索引（名字「分支」「分支 2」…），toast 后直接打开该分支。
- 消息长按菜单新增「从这里创建分支」（生成中禁用）。

### 3. 消息书签

- `lib/services/bookmarks.dart`：`ChatBookmark{timestamp,role,preview,createdAt}` + `BookmarkStore`
  （`load/save/contains/toggle/remove/clear/previewOf`），prefs 键 `chat_bookmarks_<convId>`。
  `previewOf` 压平空白并截 120 字。
- 消息长按菜单新增「书签」（加入/取消）；聊天菜单新增「书签」→ 列表（按加入时间正序，
  显示角色/时间，可删），点一条按比例滚动定位（`_jumpToMessage`）并 toast「已跳到书签位置附近」。
- 删除聊天 / 角色时清掉对应书签。

### 4. 顺手修的

- 单聊写入开场白原来写死 `card.id`，多聊天下会写错文件 → 改为 `_convId`。
- 群聊加载会话改用 `_convId`（原来写死 `Storage.groupConvId`）。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+270 全过**（新增 test/v18_test.dart 14 例：索引/书签/坏数据容错） |
| `flutter build apk --release` | 见下方运行记录 |
| 真机安装 | 见下方运行记录 |

## 真机自测清单（装上新包后）

1. 打开一个角色 → 点标题右侧的小箭头 → 「新建聊天」→ 发两句话 → 再点标题切回原来那段，确认两段内容互不干扰。
2. 聊天列表里长按/右上「⋮」→ 重命名一段；再切到另一段，删除非当前的聊天，确认消息文件被清掉。
3. 长按某条消息 → 「从这里创建分支」→ 新聊天里应该只有到那条为止的历史，继续聊不影响原聊天。
4. 长按一条消息 → 「书签」→ 菜单「书签」→ 点那条 → 应跳到附近位置；再取消书签确认列表清空。
5. 删除一个角色，确认它名下的多段聊天都不在 `conversations` 目录里残留。
6. 老数据（升级前就有的会话）打开后，聊天列表里应能看到带「（默认）」的那一段。

## 已知边界

- 聊天列表按「最近保存时间」排序；同一毫秒内保存的顺序不稳定。
- 新增聊天时单聊会写入角色开场白（`firstMes`），群聊是空对话，等用户先说话。
- 分支是**复制**历史快照，不是双向同步：分支里继续聊不会回写原聊天。
- 书签跳转按「消息序号 / 总条数」比例估算滚动位置（条高不定），落点可能偏几行。
- 删除聊天不可恢复（确认框里已写明）。
- 未做（沿用 v0.16.0 的待办）：TTS/STT、图像生成、向量长期记忆、Web 搜索、输出正则替换、
  背景图/主题深度定制、扩展系统、多角色卡「角色备注 Character's Note」等。

## 环境与命令

```powershell
="https://storage.flutter-io.cn"
C:\flutter\bin\flutter.bat analyze
C:\flutter\bin\flutter.bat test
C:\flutter\bin\flutter.bat build apk --release
C:\Users\28351\Android\Sdk\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-release.apk
```

- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）；真机 23113RKC6C，
  无线调试地址曾为 `192.168.0.105:38767`（经常离线）。
- 真机点按请用**视觉坐标**（uiautomator 的 bounds 常与视觉位置不符）。

## 本次运行记录（2026-11-22 20:34）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 静态检查 | `flutter analyze` | **No issues found!**（4.4s） |
| 单元/组件测试 | `flutter test` | **+270 All tests passed!**（v18_test.dart 14 例） |
| Release 构建 | `flutter build apk --release` | 成功，`59.0 MB`，versionCode **15** / versionName **0.17.0**（Gradle 44.0s） |
| 真机安装 | `adb install -r` | **未完成**：`adb devices` 为空，无线 `192.168.0.105:38767` 超时（10060）；手机仍停留在旧版本 |

装上新包后按上面「真机自测清单」6 步验证即可。

