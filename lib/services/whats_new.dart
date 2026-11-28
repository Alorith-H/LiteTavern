import '../app_info.dart';
import 'storage.dart';

/// 一次版本更新的说明（用于「更新后显示新功能提示」）。
class WhatsNewEntry {
  final String version;
  final String title;
  final List<String> bullets;

  const WhatsNewEntry({
    required this.version,
    required this.title,
    required this.bullets,
  });
}

/// 最近几次更新的说明。只保留用户能感知的变化，不写内部实现。
const List<WhatsNewEntry> kWhatsNew = <WhatsNewEntry>[
  WhatsNewEntry(
    version: '0.47.0',
    title: '对话更好看了',
    bullets: <String>[
      '角色回复里的强调、动作描写、「」台词、列表和代码块现在会分别排开，一眼能看出哪句是说出口的。',
      '回复生成时末尾有个闪烁光标，新消息会轻轻浮现。',
      '不习惯的话可以在「设置 → 外观与显示」里关掉「富文本渲染」和「对话动效」。',
    ],
  ),
  WhatsNewEntry(
    version: '0.46.1',
    title: '界面与创建流程微调',
    bullets: <String>[
      '默认主题色改为紫色；之前没改过颜色的会自动换成紫色。',
      '创建角色卡时的初始变量改在对话里确认，不再单独弹窗。',
    ],
  ),
  WhatsNewEntry(
    version: '0.46.0',
    title: 'AI 创建角色卡更自由',
    bullets: <String>[
      '去掉固定步骤：想怎么聊就怎么聊，AI 一次问一个问题，不再显示「第几步」。',
      '生成前会问你要不要初始变量；说不加，角色卡里就不会有变量。',
    ],
  ),
  WhatsNewEntry(
    version: '0.45.1',
    title: '长按菜单精简',
    bullets: <String>[
      '长按角色卡只显示「编辑角色」和「删除角色」两个按钮，不再显示角色名与分组标题。',
    ],
  ),
  WhatsNewEntry(
    version: '0.45.0',
    title: '角色卡与创建流程更新',
    bullets: <String>[
      '首次进入角色卡市场会先显示第三方内容说明，之后可在设置里回看。',
      'AI 创建角色卡改为六步引导，一次只聊一件事，也可以点快速选项。',
      '生成的角色卡可以带初始变量，在「变量与状态」里查看。',
      '编辑角色页新增「AI 修改」：说一句想怎么改，确认后再写回输入框。',
      '点击对话里的头像可直接进入角色编辑。',
    ],
  ),
  WhatsNewEntry(
    version: '0.44.2',
    title: '小幅更新',
    bullets: <String>[
      '修复若干界面细节，部分文案改为更简洁的表述。',
    ],
  ),
  WhatsNewEntry(
    version: '0.44.1',
    title: '界面细节调整',
    bullets: <String>[
      '新手引导最后一页重新排版，要点分组显示。',
      '导入角色卡弹窗改为四个入口平铺。',
    ],
  ),
  WhatsNewEntry(
    version: '0.44.0',
    title: '更新下载优化',
    bullets: <String>[
      '下载更新时自动选择较快的下载源。',
      '下载中断后可从断点继续。',
      '下载对话框显示当前来源与速度。',
      '设置 → 帮助与关于 → 更新下载源 可调整策略。',
    ],
  ),  WhatsNewEntry(
    version: '0.43.1',
    title: '关于页和官网都换了样子',
    bullets: <String>[
      '设置 → 帮助与关于 → 关于：现在能直接点开官网和源码。',
      '官网重新做了一版，手机上看着更舒服。',
      '市场、备份这些地方的说明文字又顺了一遍。',
    ],
  ),  WhatsNewEntry(
    version: '0.43.0',
    title: '这一版更顺手了',
    bullets: <String>[
      '第一次打开会有更清楚的引导，跟着点就行。',
      '更新后会弹出这种说明，告诉你这次改了什么。',
      '各处的说明文字重新写了一遍，少了很多「功能清单」的味道。',
      '官网已经上线，换手机或者推荐给朋友都方便。',
    ],
  ),
  WhatsNewEntry(
    version: '0.42.0',
    title: '长聊天更快了',
    bullets: <String>[
      '对话特别长时，保存只写新增的部分，不再整份重写。',
      '打开长对话先显示最近 200 条，往上滑继续加载。',
      '搜索和统计会记住结果，不用每次重新算。',
      '导出长图有进度条了，不会再像卡住一样。',
    ],
  ),
];

/// 当前版本对应的说明；没有登记就返回 null。
WhatsNewEntry? whatsNewFor(String version) {
  for (final entry in kWhatsNew) {
    if (entry.version == version) return entry;
  }
  return null;
}

/// 需要提示的更新：上次看过的版本比当前旧，且当前版本有登记说明。
WhatsNewEntry? pendingWhatsNew() {
  final entry = whatsNewFor(kAppVersion);
  if (entry == null) return null;
  if (AppSettings.lastSeenVersion == entry.version) return null;
  return entry;
}

/// 记下已经看过这一版说明。
Future<void> markWhatsNewSeen(String version) =>
    AppSettings.setLastSeenVersion(version);
