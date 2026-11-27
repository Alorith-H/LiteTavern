import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../models/chat_message.dart';
import '../services/card_scripts.dart';
import '../services/mvu_state.dart';
import '../widgets/common.dart';

/// 变量与状态（只读）：卡内初始变量 + 对话里读到的状态更新。
///
/// 轻酒馆不执行 MVU / 卡内脚本：这里只「读给你看」，不参与生成、不写回对话。
class CardStateScreen extends StatelessWidget {
  final List<CharacterCard> cards;
  final List<ChatMessage> messages;

  const CardStateScreen({
    super.key,
    required this.cards,
    required this.messages,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = cards.isEmpty
        ? MvuSnapshot.empty
        : MvuStateReader.fromCard(cards.first);
    final merged = MvuStateReader.fromMessages(messages, base: initial);
    final script = CardScriptScanner.scanAll(cards);

    return Scaffold(
      appBar: AppBar(title: const Text('变量与状态')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _NoticeCard(scheme: scheme),
          const SectionHeader('卡内初始变量'),
          if (initial.isEmpty)
            _EmptyHint(
              text: cards.isEmpty
                  ? '没有角色卡可以读取。'
                  : '这张卡没有在扩展里写初始变量。',
            )
          else
            _ValueTable(values: initial.entries, scheme: scheme),
          const SectionHeader('对话里读到的状态'),
          if (merged.updateCount == 0)
            const _EmptyHint(
              text: '这段对话里还没有出现状态更新块（<UpdateVariable> / <JSONPatch>）。',
            )
          else ...[
            Text(
              '找到 ${merged.updateCount} 个状态更新块（从聊天文本里读出来的，只读）。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            if (merged.isEmpty)
              const _EmptyHint(text: '更新块里没有可识别的变量。')
            else
              _ValueTable(values: merged.entries, scheme: scheme),
          ],
          const SectionHeader('卡内脚本与动态内容'),
          if (!script.hasScript)
            Row(
              children: [
                Icon(Icons.verified_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '没有发现卡内脚本或动态内容。',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          else
            for (final f in script.findings)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, size: 18, color: scheme.tertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.title,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            f.detail,
                            style: TextStyle(
                              fontSize: AppType.meta,
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final ColorScheme scheme;

  const _NoticeCard({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '这里只做「只读查看」：变量是从角色卡与聊天文本里读出来的，'
              '不参与发给模型的提示词，也不会改写对话；卡内脚本一律不执行。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValueTable extends StatelessWidget {
  final List<MvuValue> values;
  final ColorScheme scheme;

  const _ValueTable({required this.values, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      values[i].name,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: SelectableText(
                      values[i].value,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: AppType.caption,
        color: scheme.onSurfaceVariant,
        height: 1.5,
      ),
    );
  }
}
