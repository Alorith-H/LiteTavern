import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';
import 'api_presets.dart';

/// 用系统浏览器打开外部链接（v0.15.0）。
///
/// 失败（无浏览器、模拟器、测试环境无插件）时不抛异常，改为弹窗展示链接，
/// 并提供「复制链接」，保证用户始终拿得到地址。
Future<bool> openExternalLink(
  BuildContext context,
  String url, {
  String? title,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) {
    if (context.mounted) {
      _showLinkFallback(context, url, title: title, reason: '链接格式不对');
    }
    return false;
  }
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (!launched && context.mounted) {
    _showLinkFallback(context, url, title: title);
  }
  return launched;
}

void _showLinkFallback(
  BuildContext context,
  String url, {
  String? title,
  String? reason,
}) {
  final scheme = Theme.of(context).colorScheme;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? '手动打开链接'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reason == null
                ? '没有可用的浏览器，请复制下面的地址，用浏览器打开：'
                : '$reason，请复制下面的地址用浏览器打开：',
            style: const TextStyle(fontSize: AppType.caption),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              url,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('链接已复制，粘贴到浏览器打开'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('复制链接'),
        ),
      ],
    ),
  );
}

/// 打开「获取 API Key」帮助弹窗：一句话说明 + 官网/Key 页/文档三个按钮。
Future<void> showApiKeyHelp(
  BuildContext context, {
  required String providerLabel,
  required String keyUrl,
  String siteUrl = '',
  String docsUrl = '',
  String note = '',
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在 $providerLabel 获取 API Key',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          if (note.isNotEmpty) ...[
            Text(
              note,
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          _step('1', '打开官网，注册 / 登录（部分服务商需要实名认证）'),
          _step('2', '在控制台充值或领取免费额度（模型按量计费，费用由服务商收取）'),
          _step('3', '进入「API Keys」页面，创建并复制 Key（一般形如 sk-xxxx）'),
          _step('4', '回到 LiteTavern，把 Key 粘贴到 API Key 一栏'),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => openExternalLink(
                ctx,
                keyUrl,
                title: '$providerLabel · API Keys',
              ),
              icon: const Icon(Icons.key_rounded, size: 18),
              label: const Text('打开 API Keys 页面'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (siteUrl.isNotEmpty)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => openExternalLink(
                      ctx,
                      siteUrl,
                      title: '$providerLabel 官网',
                    ),
                    child: const Text('官网首页'),
                  ),
                ),
              if (siteUrl.isNotEmpty && docsUrl.isNotEmpty)
                const SizedBox(width: 8),
              if (docsUrl.isNotEmpty)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => openExternalLink(
                      ctx,
                      docsUrl,
                      title: '$providerLabel 文档',
                    ),
                    child: const Text('使用文档'),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 不知道自己是哪家服务商时：列出全部预设，选一个再打开取 Key 指引。
Future<void> showApiKeyProviderPicker(
  BuildContext context, {
  ApiPreset? current,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(
            current == null ? '选择你的模型服务商' : '切换服务商',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            '点一家服务商，查看「注册 → 充值 → 创建 Key」的具体步骤',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in kApiPresets)
                ListTile(
                  leading: Icon(
                    current?.keyUrl == p.keyUrl
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: current?.keyUrl == p.keyUrl
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  title: Text(p.label),
                  subtitle: Text(
                    p.note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: AppType.meta),
                  ),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showApiKeyHelp(
                      context,
                      providerLabel: p.label,
                      keyUrl: p.keyUrl,
                      siteUrl: p.siteUrl,
                      docsUrl: p.docsUrl,
                      note: p.note,
                    );
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

Widget _step(String index, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFB3A9D6).withValues(alpha: 0.28),
            shape: BoxShape.circle,
          ),
          child: Text(
            index,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: AppType.caption, height: 1.45),
          ),
        ),
      ],
    ),
  );
}
