# v0.9/v0.10 中断断点（2026-10-08 00:10 暂停）

> 下次继续：读本文件 + `task_spec_v9.txt` + `task_spec_v10.txt`，从「剩余工作」做起。
> **分工（用户指示）：Claude 只写代码+写测试代码+`flutter analyze` 清零；
> `flutter test`、构建 APK、装机、真机验证全部由 Hermes 执行 —— 规格提示词里必须注明不跑 test/build。**

## 已完成
### v0.9.0（设置两级 + 高级采样 + 按钮动画）— 约 90%
- `lib/services/sampling_params.dart`：高级采样参数模型（默认=请求不出现）
- `lib/screens/advanced_settings_screen.dart`：高级设置子页
- `lib/widgets/segmented_toggle.dart`：分段按钮（胶囊滑动动画组件）
- `api_client.dart`（默认不发送逻辑）、`storage.dart`（预设字段扩展+迁移）、
  `settings_screen.dart`（高级设置入口+流式开关）、`home_screen.dart`、
  `card_creator_screen.dart` 均有改动
- `test/v9_test.dart` 已建
- ⚠️ 未核对：home 是否真的用上 segmented_toggle、设置页入口是否齐全（逐条对照 v9 规格）

### v0.10.0（退出不中断）— 约 40%
- `lib/services/active_generations.dart`：后台生成管理器已建（23:20）
- `chat_screen.dart` 已接入（23:21）—— 是否完整符合 spec 待核对
- ❌ `card_creator_screen.dart` **未接入**（还是 18:29 旧版）
- ❌ `test/v10_test.dart` 未写

## 剩余工作（下次续跑清单）
1. 读 active_generations + chat_screen，对照 task_spec_v10.txt 核对（dispose 只解绑不
   cancel、完成落库、重进接管、防重入），补缺口
2. card_creator_screen 接入管理器（同 spec）
3. 对照 task_spec_v9.txt 核对 home/settings 残余，补缺
4. 写 test/v10_test.dart（≥5 条）+ 补齐 v9 测试缺口
5. 版本 `0.10.0+1`；只跑 `flutter analyze` 至 0；输出收尾报告
6. **Hermes 接手**：flutter test 全量 → release 构建 → 装机 → 真机验证
   （按钮动画/高级设置/退出不中断三件套）→ 提交 + 推送 GitHub

## 环境与教训
- Flutter：`export PATH="/c/Users/28351/Desktop/Project/flutter/bin:$PATH"`（或 /c/flutter/bin）
- 构建：`export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`
- **2026-10-07 夜 mimo 网关连续卡死 3 次**（18:15、22:51、00:06 轮）：
  特征 = 进程活着但 30+ 分钟零文件改动、CPU 空闲 → 杀孤儿进程重启续跑（注意 process_manage
  kill 会 420s 超时，直接 `taskkill /F /T /PID <bash_pid>` 更快，孤儿 claude 按启动时间辨认）
- 机器上可能有**用户自己的 claude 进程**（另一任务），杀前按 StartTime 认准自己的
- 远端：`origin = https://github.com/Alorith-H/LiteTavern.git`（GCM 凭据可用，dev 已跟踪）
