/// 服务商预设（chips 一键填入地址与模型，不清空已填 Key）。
///
/// 除地址与模型外，还带上「官网 / 获取 Key 页面 / 文档」三处链接，
/// 供新手指引与配置页提供「去官网获取 API Key」入口（v0.15.0）。
///
/// v0.20.0：新增 [free]（是否免费模型）与 [contextWindow]（该模型的上下文长度），
/// 引导页把「智谱 GLM-4-Flash（免费）」放在第一位，新手零成本就能跑起来。
class ApiPreset {
  final String label;
  final String baseUrl;
  final String model;

  /// 平台首页（控制台入口）。
  final String siteUrl;

  /// 直接打开「创建 / 复制 API Key」的页面。
  final String keyUrl;

  /// 官方文档（可选，空串表示没有）。
  final String docsUrl;

  /// 一句话提示：是否需要充值、Key 长什么样、本地模型怎么开。
  final String note;

  /// 是否免费模型（引导页会打「免费」徽章）。
  final bool free;

  /// 这个模型能吃多少 token 的上下文（选模型时自动带进上下文长度）。
  final int contextWindow;

  const ApiPreset(
    this.label,
    this.baseUrl,
    this.model, {
    required this.siteUrl,
    required this.keyUrl,
    this.docsUrl = '',
    this.note = '',
    this.free = false,
    this.contextWindow = 65536,
  });
}

const kApiPresets = <ApiPreset>[
  // 免费、零门槛，放第一位：新手不用充值就能先玩起来。
  ApiPreset(
    '智谱 GLM-4-Flash',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4-flash',
    siteUrl: 'https://bigmodel.cn/',
    keyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
    docsUrl: 'https://docs.bigmodel.cn/cn/guide/develop/http/introduction',
    note: '完全免费（有速率限制）；手机号注册并实名即可拿 Key',
    free: true,
    contextWindow: 128000,
  ),
  ApiPreset(
    '智谱 GLM-4-Air',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4-air',
    siteUrl: 'https://bigmodel.cn/',
    keyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
    docsUrl: 'https://docs.bigmodel.cn/cn/guide/develop/http/introduction',
    note: '按量付费（送部分免费额度）；Key 形如 xxxxxxxx.xxxxxxxx',
    contextWindow: 128000,
  ),
  ApiPreset(
    'DeepSeek',
    'https://api.deepseek.com/v1',
    'deepseek-chat',
    siteUrl: 'https://platform.deepseek.com/',
    keyUrl: 'https://platform.deepseek.com/api_keys',
    docsUrl: 'https://api-docs.deepseek.com/zh-cn/',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
    contextWindow: 65536,
  ),
  ApiPreset(
    'Kimi',
    'https://api.moonshot.cn/v1',
    'moonshot-v1-8k',
    siteUrl: 'https://platform.kimi.com/',
    keyUrl: 'https://platform.kimi.com/console/api-keys',
    docsUrl: 'https://platform.moonshot.cn/docs/api',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
    contextWindow: 8192,
  ),
  ApiPreset(
    '小米 MiMo',
    'https://api.xiaomimimo.com/v1',
    'mimo-v2.6-flash',
    siteUrl: 'https://platform.xiaomimimo.com/',
    keyUrl: 'https://platform.xiaomimimo.com/#/console/api-keys',
    docsUrl: 'https://mimo.mi.com/docs/zh-CN/quick-start/summary/first-api-call',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
    contextWindow: 65536,
  ),
  ApiPreset(
    'Ollama（局域网）',
    'http://192.168.x.x:11434/v1',
    'qwen2.5:7b',
    siteUrl: 'https://ollama.com/',
    keyUrl: 'https://ollama.com/download',
    docsUrl: 'https://github.com/ollama/ollama/blob/main/docs/openai.md',
    note: '本地运行、无需 Key；先安装 Ollama 并下载模型',
    contextWindow: 32768,
  ),
];

/// 按地址找预设（用于配置页判断「当前填的是哪家」，找不到返回 null）。
ApiPreset? presetForBaseUrl(String baseUrl) {
  final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  for (final preset in kApiPresets) {
    if (preset.baseUrl.replaceAll(RegExp(r'/+$'), '') == normalized) {
      return preset;
    }
  }
  return null;
}

/// 按模型名猜上下文长度（找不到时返回 [fallback]，默认 65536）。
///
/// 只在「获取模型列表」选模型、或配置里留空（0 = 自动）时用；
/// 猜错的代价只是压缩阈值不准，不会让请求失败（宁可保守）。
int contextWindowForModel(String model, {int fallback = 65536}) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return fallback;

  // 精确型号优先（后缀带窗口大小的）
  final windowSuffix = RegExp(r'-(\d+)k$').firstMatch(m);
  if (windowSuffix != null) {
    final k = int.tryParse(windowSuffix.group(1)!);
    if (k != null && k > 0) return k * 1024;
  }

  // 各家主力模型
  if (m.startsWith('glm-4') || m.startsWith('glm-3')) return 128000;
  if (m.startsWith('glm-5')) return 200000;
  if (m.startsWith('deepseek')) return 65536;
  if (m.startsWith('kimi') || m.startsWith('moonshot')) return 131072;
  if (m.startsWith('mimo')) return 65536;
  if (m.startsWith('gpt-4o') ||
      m.startsWith('gpt-4.1') ||
      m.startsWith('gpt-4-turbo')) {
    return 128000;
  }
  if (m.startsWith('gpt-5') || m.startsWith('o1') || m.startsWith('o3')) {
    return 200000;
  }
  if (m.startsWith('gemini')) return 1000000;
  if (m.startsWith('claude')) return 200000;
  if (m.startsWith('qwen')) return 131072;
  if (m.startsWith('llama') || m.startsWith('mistral')) return 32768;
  return fallback;
}

/// 128000 → 「128K」；1048576 → 「1M」；不足 1000 原样。
String formatContextWindow(int tokens) {
  if (tokens <= 0) return '自动';
  if (tokens >= 1000000) {
    final m = tokens / 1000000;
    return '${m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
  }
  if (tokens >= 1024) {
    final k = tokens / 1024;
    return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}K';
  }
  return '$tokens';
}
