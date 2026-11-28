/// AI 创建角色卡的逐步引导流程（v0.45.0）。
///
/// 以前是一次性自由采访：AI 一次问两个问题，用户想到哪说到哪，容易漏。
/// 现在改成固定 6 步，一次只聊一件事：

/// 名字与题材 → 性格与说话方式 → 外貌与背景 → 场景与开场白 →
/// 变量与状态 → 世界书要点。
///
/// 本文件只放纯数据与纯函数（不依赖 Flutter / 网络），既给界面提供
/// 步骤标题与快速选项，也用来拼提示词和生成前的结构化摘要，方便测试。
library;

/// 引导步骤。顺序即界面上的 1–6。
enum CreatorStep {
  /// 1. 名字与题材
  basics,

  /// 2. 性格与说话方式
  personality,

  /// 3. 外貌与背景
  appearance,

  /// 4. 场景与开场白
  scene,

  /// 5. 变量与状态
  variables,

  /// 6. 世界书要点
  worldbook;

  /// 界面上显示的序号（1 起）。
  int get number => index + 1;

  /// 步骤标题。
  String get label => switch (this) {
        CreatorStep.basics => '名字与题材',
        CreatorStep.personality => '性格与说话方式',
        CreatorStep.appearance => '外貌与背景',
        CreatorStep.scene => '场景与开场白',
        CreatorStep.variables => '变量与状态',
        CreatorStep.worldbook => '世界书要点',
      };

  /// 这一步 AI 要问的问题（拼进系统提示，也用作空态引导）。
  String get question => switch (this) {
        CreatorStep.basics => '这个角色叫什么？想放在什么题材里（奇幻、校园、科幻、日常……）？',
        CreatorStep.personality =>
          'TA 的性格是什么样的？说话有什么习惯（话少、爱开玩笑、说话文绉绉……）？',
        CreatorStep.appearance => 'TA 的外貌和来历呢？年纪、穿着、过去发生过什么？',
        CreatorStep.scene => '第一次见面是什么场景？TA 开口说的第一句话大概是什么？',
        CreatorStep.variables =>
          '这个角色需要记什么数值吗？比如好感度、体力、金钱、时间；没有就跳过。',
        CreatorStep.worldbook =>
          '还有需要固定下来的专有名词吗？地名、组织、规则、称呼；没有就跳过。',
      };

  /// 输入框提示。
  String get hint => switch (this) {
        CreatorStep.basics => '例如：叫林雾，都市奇幻，开一家只在夜里营业的店',
        CreatorStep.personality => '例如：话不多，句子很短，偶尔有点毒舌',
        CreatorStep.appearance => '例如：二十七八岁，黑发，总穿旧毛衣，以前是记者',
        CreatorStep.scene => '例如：深夜她推开店门，问这里还收不收留人',
        CreatorStep.variables => '例如：好感度 0、体力 100、钱 50',
        CreatorStep.worldbook => '例如：夜灯街、守夜人、收留规则',
      };

  /// 快速选项：点一下直接作为回答发出（也可以自己写）。
  List<String> get quickOptions => switch (this) {
        CreatorStep.basics => const ['都市奇幻', '校园日常', '科幻悬疑', '古风江湖'],
        CreatorStep.personality => const ['简短冷淡', '温柔耐心', '爱开玩笑', '毒舌但心软'],
        CreatorStep.appearance => const ['二十多岁', '神秘中年人', '非人类外表', '不强调外貌'],
        CreatorStep.scene => const ['深夜相遇', '工作场合', '意外搭救', '久别重逢'],
        CreatorStep.variables => const ['好感度', '体力', '金钱', '不需要'],
        CreatorStep.worldbook => const ['一个地名', '一个组织', '一条规则', '不需要'],
      };
}

/// 每个角色最多 6 步；数值不超过它。
const int kCreatorStepCount = 6;

/// 逐步引导的会话状态：当前第几步、每步用户答了什么。
///
/// 只做「记下答案 + 推进步骤」两件事，AI 回复仍由界面负责请求；
/// 步骤推进在用户发出回答之后由界面调用 [advance]。
class CardCreatorFlow {
  CreatorStep _step = CreatorStep.basics;
  final Map<CreatorStep, String> _answers = {};

  /// 当前步骤。
  CreatorStep get step => _step;

  /// 当前步骤序号（1 起）。
  int get stepNumber => _step.number;

  /// 是否停在最后一步。
  bool get isLast => _step == CreatorStep.values.last;

  /// 是否已经走完（界面用来把主按钮从「下一步」切成「生成角色卡」）。
  bool get isComplete => _step == CreatorStep.values.last && _answers.containsKey(_step);

  /// 已记录答案的步骤数。
  int get answeredCount => _answers.length;

  /// 是否一条答案都没有。
  bool get isEmpty => _answers.isEmpty;

  /// 进度（0–1），给进度条用。
  double get progress => answeredCount / kCreatorStepCount;

  /// 「第 2/6 步 · 性格与说话方式」。
  String get progressLabel => '第 $stepNumber/$kCreatorStepCount 步 · ${_step.label}';

  /// 当前步骤的答案（没答过返回空串）。
  String answerFor(CreatorStep step) => _answers[step] ?? '';

  /// 记录当前步骤的答案。空白内容不记录、不推进。
  bool record(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    _answers[_step] = t;
    return true;
  }

  /// 进入下一步。已在最后一步返回 false。
  bool advance() {
    if (isLast) return false;
    _step = CreatorStep.values[_step.index + 1];
    return true;
  }

  /// 跳过当前步骤：不记答案，直接前进。
  bool skip() => advance();

  /// 回到上一步（用于「改一下上一步」）。
  bool back() {
    if (_step.index == 0) return false;
    _step = CreatorStep.values[_step.index - 1];
    return true;
  }

  /// 清空。
  void reset() {
    _step = CreatorStep.basics;
    _answers.clear();
  }

  /// 生成角色卡时给模型的结构化摘要（按步骤顺序，只含答过的）。
  String summaryForPrompt() {
    final buf = StringBuffer('用户逐步确认的设定：\n');
    for (final step in CreatorStep.values) {
      final a = _answers[step];
      if (a == null || a.isEmpty) continue;
      buf.writeln('- ${step.label}：$a');
    }
    return buf.toString();
  }

  /// 测试 / 调试用：只读快照。
  Map<CreatorStep, String> get answers => Map.unmodifiable(_answers);
}

/// 逐步引导的系统提示：让 AI 只围绕当前这一步追问，不跳步。
///
/// [answers] 用于在提示里带上「已经确认过的内容」，避免重复提问。
String creatorInterviewSystem(CardCreatorFlow flow) {
  final done = StringBuffer();
  for (final step in CreatorStep.values) {
    final a = flow.answerFor(step);
    if (a.isNotEmpty) done.writeln('- ${step.label}：$a');
  }
  return '''
你是角色卡创作的采访者（出题人），不是角色扮演者，不要进入任何虚构场景。
用户想创建一张 AI 角色卡，现在按固定步骤收集信息，当前是第 ${flow.stepNumber}/$kCreatorStepCount 步「${flow.step.label}」。

规则：
- 先用一句话确认用户刚才说的内容，再问当前这一步的问题，不要跳到后面的步骤；
- 每次只问一个问题，口语化、具体，方便一句话回答；
- 用户已经答过的内容不要重复问（见下方「已确认」）；
- 如果用户说「跳过」「不知道」，就简短说明会用默认设定，然后问当前步骤的下一个问题，不要纠缠；
- 始终用中文，回复控制在三句话以内，不要写 JSON，不要提前生成角色卡。

${done.isEmpty ? '已确认：暂无' : '已确认：\n$done'}
当前这一步要问的：${flow.step.question}
''';
}

/// 跟随某一步的「确认并进入下一步」提示（作为临时系统消息追加）。
String creatorStepTransitionHint(CardCreatorFlow flow) => '''
用户已经回答了上一步。现在进入第 ${flow.stepNumber}/$kCreatorStepCount 步「${flow.step.label}」。
请先用一句话简短确认用户上一步说的内容，然后再问：${flow.step.question}
不要输出其它内容。
''';
