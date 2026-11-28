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
