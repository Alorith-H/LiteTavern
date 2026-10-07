/// 服务商预设（chips 一键填入地址与模型，不清空已填 Key）。
class ApiPreset {
  final String label;
  final String baseUrl;
  final String model;
  const ApiPreset(this.label, this.baseUrl, this.model);
}

const kApiPresets = <ApiPreset>[
  ApiPreset('小米 MiMo', 'https://api.xiaomimimo.com/v1', 'mimo-v2.6-flash'),
  ApiPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  ApiPreset('Kimi', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
  ApiPreset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-air'),
  ApiPreset('Ollama（局域网）', 'http://192.168.x.x:11434/v1', 'qwen2.5:7b'),
];
