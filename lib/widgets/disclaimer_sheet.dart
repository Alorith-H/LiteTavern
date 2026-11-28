import 'package:flutter/material.dart';

import '../services/market_disclaimer.dart';
import 'common.dart';
import 'sheet_menu.dart';

/// 角色卡市场的第三方内容说明（v0.45.0）。
///
/// 两种用法：
/// - 首次进入市场：`showMarketDisclaimer(context)`，在市场页加载数据前调用；
///   返回 true 表示「了解并继续」，返回 false 表示用户不同意（市场页应退出）。
///   这一种是全屏页面：正文较长，整页展示比半屏弹层更容易读完。
/// - 设置里回看：`showMarketDisclaimer(context, readOnly: true)`，底部弹层只读展示，
///   另有「重新确认」把确认状态清掉，下次进市场会重新提示。
///
/// 说明内容必须覆盖：内容来自第三方平台（Chub.ai）、由第三方用户上传、
/// 与本软件及作者无关、用户自行判断是否使用、可改用 AI 生成 / 本地导入、
/// 本软件不审核也不担保。
Future<bool> showMarketDisclaimer(
  BuildContext context, {
  bool readOnly = false,
}) async {
  if (readOnly) {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _MarketDisclaimerSheet(),
    );
    return result ?? false;
  }
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _MarketDisclaimerPage(),
  );
  return result ?? false;
}

/// 首次进入市场时的整页说明：底部固定「不同意 / 我了解并继续」。
class _MarketDisclaimerPage extends StatelessWidget {
  const _MarketDisclaimerPage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog.fullscreen(
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '角色卡市场使用提示',
                    style: TextStyle(
                      fontSize: AppType.page,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '这里的角色卡都来自第三方平台，继续前请先了解这些内容由谁负责。',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: disclaimerBlocks(context),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: _consentActions(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置里回看用的只读弹层。
class _MarketDisclaimerSheet extends StatelessWidget {
  const _MarketDisclaimerSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SheetMenuTitle(
                    title: '角色卡市场使用提示',
                    subtitle: '这里的角色卡都来自第三方平台，内容由上传者负责。',
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ...disclaimerBlocks(context),
                        _status(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: _readOnlyActions(context),
          ),
        ],
      ),
    );
  }
}

/// 说明正文的几段，两种展示方式共用。
List<Widget> disclaimerBlocks(BuildContext context) {
  return <Widget>[
    _block(
      context,
      title: '内容来自第三方用户',
      body: '角色卡市场展示的角色卡来自 Chub.ai 等第三方平台，由其他用户自行上传和维护。'
          '角色设定、头像、简介、标签都不是 LiteTavern 提供的内容。',
    ),
    _block(
      context,
      title: '与本软件及作者无关',
      body: '上传者对其发布的内容负责。这些内容不代表本软件的立场，与本软件及其开发者无关，'
          '也可能与软件内置设定不符；本软件不对其合法性、准确性、适用性作任何判断。',
    ),
    _block(
      context,
      title: '不存储，不审核，也不担保',
      body: '本软件不存储、不审核第三方角色卡的内容，无法保证其中的文字、图片适合所有人。'
          '请你自行判断是否下载、是否与某个角色对话，由此产生的一切后果由你自行承担。',
    ),
    _block(
      context,
      title: '你可以选择不用',
      body: '市场只是可选入口。也可以用「创建角色」自己写设定、让 AI 生成角色卡，'
          '或从本地导入自己的角色卡文件。',
    ),
    Text(
      '继续使用即表示你已知悉上述情况，并同意自行承担使用第三方内容的风险。',
      style: TextStyle(
        fontSize: AppType.caption,
        height: 1.55,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  ];
}

/// 一段「小标题 + 说明」，行高放宽方便长文阅读，不加减号不装饰。
Widget _block(
  BuildContext context, {
  required String title,
  required String body,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppType.body,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: TextStyle(
            fontSize: AppType.caption,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

Widget _consentActions(BuildContext context) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('不同意'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 2,
        child: FilledButton(
          onPressed: () async {
            await MarketDisclaimer.accept();
            if (context.mounted) Navigator.of(context).pop(true);
          },
          child: const Text('我了解并继续'),
        ),
      ),
    ],
  );
}

Widget _readOnlyActions(BuildContext context) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            await MarketDisclaimer.reset();
            if (!context.mounted) return;
            Navigator.of(context).pop(false);
            messenger.showSnackBar(
              const SnackBar(content: Text('已清除确认状态，下次进入角色卡市场会重新提示')),
            );
          },
          child: const Text('重新确认'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ),
    ],
  );
}

/// 只读模式下显示当前确认状态（确认过哪一版 / 还没确认）。
Widget _status(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return FutureBuilder<int>(
    future: MarketDisclaimer.acceptedVersion(),
    builder: (context, snapshot) {
      final version = snapshot.data ?? 0;
      final accepted = version >= MarketDisclaimer.currentVersion;
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              accepted ? '当前状态：已确认（第 $version 版）' : '当前状态：未确认',
              style: TextStyle(
                fontSize: AppType.meta,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '想再看一次首次进入时的提示，可以点「重新确认」：确认状态会被清除，'
              '下次打开角色卡市场时会重新弹出。',
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.55,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    },
  );
}
