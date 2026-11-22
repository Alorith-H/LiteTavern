# 轻酒馆 LiteTavern

> 简洁、克制的 AI 角色扮演聊天 App。兼容 SillyTavern 角色卡与世界书，直连任意 OpenAI 兼容接口。

[![Release](https://img.shields.io/github/v/release/Alorith-H/LiteTavern?sort=semver&label=Release)](https://github.com/Alorith-H/LiteTavern/releases)
[![Platform](https://img.shields.io/badge/platform-Android%207.0%2B-3ddc84)](https://github.com/Alorith-H/LiteTavern/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569b?logo=flutter&logoColor=white)](https://flutter.dev)
[![Tests](https://img.shields.io/badge/tests-208%20passed-brightgreen)](#开发)
[![License](https://img.shields.io/github/license/Alorith-H/LiteTavern)](LICENSE)

**作者：Alorith** · 问题与建议：[Issues](https://github.com/Alorith-H/LiteTavern/issues)

## 简介

轻酒馆（LiteTavern）是一个 Android 端的 AI 角色扮演客户端：不内嵌模型，你填入自己的 API 地址与密钥后即可开始。界面走深色极简风，把注意力留给对话本身；功能上对齐 SillyTavern 的核心玩法，并补齐了后台生成、上下文管理、角色卡市场等日常会用到的细节。

## 功能

### 对话
- **单人聊天**：与单个角色长期对话，支持重新生成、继续生成、编辑消息、多版本变体切换。
- **群聊**：多个角色同场，按顺序轮转发言，各自人设；单人/群聊以胶囊滑动切换。
- **流式输出**：逐字显示，可在设置里关闭改为整段返回。
- **后台生成**：退出会话页不会中断生成，回来自动接管并恢复「停止」按钮；停止即取消请求。

### 提示词与上下文
- **角色卡与世界书**：解析 SillyTavern `chara_card_v2` 卡片（PNG/JSON）与世界书（关键词触发注入）。
- **提示词构建**：系统提示、{{char}} / {{user}} 宏、深度提示、示例对话按配置拼装。
- **上下文管理**：历史条数与 token 预算裁剪、超长自动摘要、真实/估算 token 记账。
- **上下文占用**：输入框上方一行细线提示当前占用百分比，点开可看系统/世界书/摘要/历史的分项。

### 生成参数
- **预设系统**：多套生成预设，激活的预设对**所有**出网请求（聊天、摘要、建卡）统一生效。
- **真实采样参数**：temperature、top_p、max_tokens；高级设置含 frequency/presence/repetition penalty、top_k、min_p、seed、stop 序列（默认值不会出现在请求里）。

### 建议回复
- 开启后，AI 回复完成会给出 **3 条不同语气/风格**、贴合角色卡与当前剧情的**你可发送的话**，点选即作为你的消息发出；也可随时 ✨ 换一批。

### 角色卡市场
- 内置 [Chub.ai](https://chub.ai) 搜索：关键词、排序（相关/热门/新上架/趋势/随机/名称）、标签（可选可输入，最多 8 个）、排除标签、语言、token 长度、最少标签数、图片/Lore/表情等高级筛选。
- 列表同时展示**原文与译文**，单卡可按需翻译；NSFW 卡片带明确标记。
- 一键下载并导入，下载过程显示进度。

### 翻译
- 翻译源按顺序自动尝试：**必应（Azure Key）→ 本地 LibreTranslate → 必应网页版 → MyMemory → Google**，都失败时才报出**预计消耗 token**，由你确认是否改用自己配置的模型翻译。
- 在 设置 → 翻译 里填入 Azure 翻译 Key（免费层每月 200 万字符）即可用最稳的必应引擎；也可以填自己电脑上跑的 **LibreTranslate** 地址（免费、不限额度，手机与电脑连同一个 WiFi）；都不填则用免 Key 的公共免费源。
- 角色编辑页可整卡翻译（原文/译文对照、一键应用、可恢复原文）。

### 其他
- 角色卡导入/导出、从链接下载角色卡、聊天记录导出。
- 深色主题、可调字号、快捷回复、命中率统计。

## 下载

到 [Releases](https://github.com/Alorith-H/LiteTavern/releases) 下载最新的 `app-release.apk` 直接安装。

- 系统要求：Android 7.0（API 24）及以上。
- 若提示「未知来源」，在系统设置中允许安装即可。
- 升级安装不会覆盖本地角色与聊天记录（同签名）。

## 快速开始

1. 安装后首次启动，填写 **API Base URL**（如 `https://api.openai.com/v1` 或任意兼容网关）、**API Key**、**模型名**，点「测试连接」。
2. 导入一张角色卡：主页右下「导入」→ 从文件选择，或直接进「角色卡市场」下载。
3. 进入角色开始聊天；长按消息可编辑/重新生成/切变体。

> 本 App 不提供、不代理任何模型服务，所有请求由你的设备直连你配置的接口。

## 技术栈

- Flutter 3.x / Dart 3，Material 3，零三方 UI 框架
- 状态与存储：`SharedPreferences` + 本地文件（角色卡、头像、聊天记录）
- 网络：`http`，SSE 流式解析，30s 超时与 50MB 下载上限
- 无代码生成、无状态管理库，纯 `StatefulWidget` + 服务层单例

## 开发

```bash
flutter pub get
flutter analyze          # 期望：No issues found!
flutter test             # 期望：208 tests passed
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

国内网络可先设置镜像再构建：

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

### 目录结构

```
lib/
├── main.dart                 入口、主题
├── app_info.dart             版本号常量（与 pubspec 同步，version_test 校验）
├── models/                   角色卡、消息、群聊、世界书、译文
├── screens/                  主页、聊天、设置、编辑、群聊、市场、创建器、引导
├── services/                 存储、API、提示词、世界书、摘要、生成管理、
│                             市场、翻译、导出、token 估算等
└── widgets/                  通用组件、分段胶囊、建议回复条
test/                         单元 + Widget 测试（13 个文件，208 例）
```

## 已知边界

- 后台生成依赖进程存活：进程被系统杀死时进行中的请求会丢失（已落库的内容不受影响）。
- 建议回复是概率性生成，语气与贴合度取决于所用模型。
- 免费翻译额度有限（约 5k 字符/天），超出后会走模型报价流程。
- 角色卡市场数据来自 Chub.ai，卡片与图片版权归原作者所有。

## 致谢

- [SillyTavern](https://github.com/SillyTavern/SillyTavern)：角色卡与世界书格式的事实标准。
- [Chub.ai](https://chub.ai)：公开角色卡数据来源。
- [MyMemory](https://mymemory.translated.net)：免费翻译接口。

## License

[MIT](LICENSE) © Alorith
