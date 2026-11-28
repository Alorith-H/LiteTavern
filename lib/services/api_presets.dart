/// 服务商预设（chips 一键填入地址与模型，不清空已填 Key）。
///
/// 除地址与模型外，还带上「官网 / 获取 Key 页面 / 文档」三处链接，
/// 供新手指引与配置页提供「去官网获取 API Key」入口（v0.15.0）。
///
/// v0.20.0：新增 [free]（是否免费模型）与 [contextWindow]（该模型的上下文长度）。
/// v0.22.0：默认第一家改回 DeepSeek；智谱只保留一家、不再区分具体 GLM 型号，也不再打「免费」标。
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
  // 默认第一家：价格便宜、注册简单，新手最容易跑起来（v0.22.0 起放第一位）。
  ApiPreset(
    'DeepSeek',
    'https://api.deepseek.com/v1',
    'deepseek-flash',
    siteUrl: 'https://platform.deepseek.com/',
    keyUrl: 'https://platform.deepseek.com/api_keys',
    docsUrl: 'https://api-docs.deepseek.com/zh-cn/',
    note: '按量付费，需先充值；1M 上下文；Key 形如 sk-xxxx',
    contextWindow: 1000000,
  ),
  // 智谱只留一家（v0.22.0）：不预设具体 GLM 型号，模型名可以自己改或从列表里挑。
  // v0.40.3：按官方文档核对——GLM-4.6 / 4.7 / 5.x 均为 200K 上下文；
  // 免费型号 glm-4.6v-flash 是 128K，可在模型列表里换成它。
  ApiPreset(
    '智谱 GLM',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4.6',
    siteUrl: 'https://bigmodel.cn/',
    keyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
    docsUrl: 'https://docs.bigmodel.cn/cn/guide/develop/http/introduction',
    note: '按量付费；GLM-4.6 为 200K 上下文；免费型号 glm-4.6v-flash 为 128K',
    contextWindow: 200000,
  ),
  // v0.40.3：moonshot-v1-* 系列已全部下线，官方现役是 kimi-k3.1-pro / kimi-k3，
  // 上下文均为 1M（platform.kimi.com/docs/models）。
  ApiPreset(
    'Kimi',
    'https://api.moonshot.cn/v1',
    'kimi-k3.1-pro',
    siteUrl: 'https://platform.kimi.com/',
    keyUrl: 'https://platform.kimi.com/console/api-keys',
    docsUrl: 'https://platform.kimi.com/docs/models',
    note: '按量付费；Kimi K3.1 Pro 为 1M 上下文；Key 形如 sk-xxxx',
    contextWindow: 1000000,
  ),
  // v0.40.3：官方规格页写 MiMo-V2.6-Flash 上下文 1M、最大输出 128K。
  ApiPreset(
    '小米 MiMo',
    'https://api.xiaomimimo.com/v1',
    'mimo-v2.6-flash',
    siteUrl: 'https://platform.xiaomimimo.com/',
    keyUrl: 'https://platform.xiaomimimo.com/#/console/api-keys',
    docsUrl: 'https://mimo.mi.com/docs/zh-CN/quick-start/summary/first-api-call',
    note: '按量付费；MiMo-V2.6-Flash 为 1M 上下文；Key 形如 sk-xxxx',
    contextWindow: 1000000,
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

  // 各家主力模型（v0.40.2 起按官方文档核对：
  // DeepSeek V4.1-Flash / V4-Pro 均 1M；智谱 GLM-4.6/4.7/5.x 200K、GLM-4 老型号 128K；
  // Kimi K3.1/K3 1M、K2 256K；MiMo V2.6 1M；GPT-6.x 1.05M、GPT-5 400K、GPT-4.1 1M、GPT-4o 128K；
  // Gemini 4/3/2.5 1M；Claude 200K（1M 为 beta）；Qwen3.8 1M、Qwen3 128K）。
  if (m.startsWith('glm-4.6') || m.startsWith('glm-4.7') || m.startsWith('glm-5')) {
    return 200000;
  }
  if (m.startsWith('glm-4') || m.startsWith('glm-3')) return 128000;
  if (m.startsWith('deepseek')) return 1000000;
  if (m.startsWith('kimi-k3')) return 1000000;
  if (m.startsWith('kimi-k2')) return 262144;
  if (m.startsWith('kimi') || m.startsWith('moonshot')) return 131072;
  if (m.startsWith('mimo')) return 1000000;
  if (m.startsWith('gpt-6')) return 1050000;
  if (m.startsWith('gpt-5')) return 400000;
  if (m.startsWith('gpt-4.1')) return 1000000;
  if (m.startsWith('gpt-4o') || m.startsWith('gpt-4-turbo')) return 128000;
  if (m.startsWith('o1') ||
      m.startsWith('o3') ||
      m.startsWith('o4')) {
    return 200000;
  }
  if (m.startsWith('gemini')) return 1000000;
  if (m.startsWith('claude')) return 200000;
  if (m.startsWith('qwen3.8') || m.startsWith('qwen3-8')) return 1000000;
  if (m.startsWith('qwen')) return 131072;
  if (m.startsWith('llama') ||
      m.startsWith('mistral') ||
      m.startsWith('mixtral')) {
    return 32768;
  }
  return fallback;
}

/// 128000 → 「128K」；1048576 → 「1M」；不足 1000 原样。
///
/// v0.21.1 修正：整 1024 的倍数按 1024 折算（65536 → 64K，131072 → 128K），
/// 否则按 1000 折算后取整（128000 → 128K），避免出现「125K」这种别扭写法。
String formatContextWindow(int tokens) {
  if (tokens <= 0) return '自动';
  if (tokens >= 1000000) {
    final m = tokens / 1000000;
    return '${m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
  }
  if (tokens >= 1000) {
    // 服务商常按十进制写（128000 = 128K），本地模型常按 1024 写（131072 = 128K）
    if (tokens % 1000 == 0) return '${tokens ~/ 1000}K';
    if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
    return '${(tokens / 1000).round()}K';
  }
  return '$tokens';
}
