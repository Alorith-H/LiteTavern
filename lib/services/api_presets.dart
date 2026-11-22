/// 服务商预设（chips 一键填入地址与模型，不清空已填 Key）。
///
/// 除地址与模型外，还带上「官网 / 获取 Key 页面 / 文档」三处链接，
/// 供新手指引与配置页提供「去官网获取 API Key」入口（v0.15.0）。
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

  const ApiPreset(
    this.label,
    this.baseUrl,
    this.model, {
    required this.siteUrl,
    required this.keyUrl,
    this.docsUrl = '',
    this.note = '',
  });
}

const kApiPresets = <ApiPreset>[
  ApiPreset(
    '小米 MiMo',
    'https://api.xiaomimimo.com/v1',
    'mimo-v2.6-flash',
    siteUrl: 'https://platform.xiaomimimo.com/',
    keyUrl: 'https://platform.xiaomimimo.com/#/console/api-keys',
    docsUrl: 'https://mimo.mi.com/docs/zh-CN/quick-start/summary/first-api-call',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
  ),
  ApiPreset(
    'DeepSeek',
    'https://api.deepseek.com/v1',
    'deepseek-chat',
    siteUrl: 'https://platform.deepseek.com/',
    keyUrl: 'https://platform.deepseek.com/api_keys',
    docsUrl: 'https://api-docs.deepseek.com/zh-cn/',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
  ),
  ApiPreset(
    'Kimi',
    'https://api.moonshot.cn/v1',
    'moonshot-v1-8k',
    siteUrl: 'https://platform.kimi.com/',
    keyUrl: 'https://platform.kimi.com/console/api-keys',
    docsUrl: 'https://platform.moonshot.cn/docs/api',
    note: '按量付费，需先充值；Key 形如 sk-xxxx',
  ),
  ApiPreset(
    '智谱 GLM',
    'https://open.bigmodel.cn/api/paas/v4',
    'glm-4-air',
    siteUrl: 'https://bigmodel.cn/',
    keyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
    docsUrl: 'https://docs.bigmodel.cn/cn/guide/develop/http/introduction',
    note: '需实名认证；有免费额度模型（如 glm-4-flash）',
  ),
  ApiPreset(
    'Ollama（局域网）',
    'http://192.168.x.x:11434/v1',
    'qwen2.5:7b',
    siteUrl: 'https://ollama.com/',
    keyUrl: 'https://ollama.com/download',
    docsUrl: 'https://github.com/ollama/ollama/blob/main/docs/openai.md',
    note: '本地运行、无需 Key；先安装 Ollama 并下载模型',
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
