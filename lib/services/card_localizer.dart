// 把一张（通常是非中文的）角色卡本地化成中文：
// 翻 名字/简介/性格/场景/开场白/示例对话/标签 → 返回替换过译文的卡，
// 同时把原文备份进 TranslationStore（角色编辑页可「查看原文 / 恢复原文」）。
import '../models/card_translation.dart';
import '../models/character_card.dart';
import 'translation_store.dart';
import 'translator.dart';

class CardLocalizer {
  final TranslationService translator;

  CardLocalizer({TranslationService? translator})
      : translator = translator ?? TranslationService();

  /// 用模型翻这张卡大概要花多少 token（询问用户时展示）。
  static int estimateTokens(CharacterCard card) =>
      TranslationService.estimateTranslationTokens(_fieldTexts(card));

  static List<String> _fieldTexts(CharacterCard card) => <String>[
        card.name,
        card.description,
        card.personality,
        card.scenario,
        card.firstMes,
        card.mesExample,
        card.tags.join(', '),
      ];

  /// 翻译并返回译文替换后的新卡（id / systemPrompt / 世界书 等保持原样）。
  ///
  /// [allowLlm] = true 才允许消耗模型额度；免费源全挂且不允许时会抛
  /// [TranslationUnavailable]（带预估 token）。
  Future<CharacterCard> localize(CharacterCard card, {bool allowLlm = false}) async {
    final fields = _fieldTexts(card);
    final indexes = <int>[];
    final texts = <String>[];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].trim().isNotEmpty) {
        indexes.add(i);
        texts.add(fields[i].trim());
      }
    }
    if (texts.isEmpty) return card;

    final results = await translator.translateAll(texts, allowLlm: allowLlm);
    final out = List<String>.filled(fields.length, '');
    for (var i = 0; i < indexes.length && i < results.length; i++) {
      out[indexes[i]] = results[i].text.trim();
    }
    final provider = results.isEmpty ? '' : results.first.provider;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (card.id.isNotEmpty) {
      await TranslationStore.saveOriginalCard(card.id, card);
      await TranslationStore.saveCard(
        card.id,
        CardTranslation(
          name: out[0],
          description: out[1],
          personality: out[2],
          scenario: out[3],
          firstMes: out[4],
          mesExample: out[5],
          tags: out[6].isEmpty ? const <String>[] : splitTags(out[6]),
          provider: provider,
          updatedAt: now,
        ),
      );
    }

    return CharacterCard(
      name: out[0].isNotEmpty ? out[0] : card.name,
      description: out[1].isNotEmpty ? out[1] : card.description,
      personality: out[2].isNotEmpty ? out[2] : card.personality,
      scenario: out[3].isNotEmpty ? out[3] : card.scenario,
      firstMes: out[4].isNotEmpty ? out[4] : card.firstMes,
      mesExample: out[5].isNotEmpty ? out[5] : card.mesExample,
      systemPrompt: card.systemPrompt,
      alternateGreetings: card.alternateGreetings,
      tags: out[6].isNotEmpty ? splitTags(out[6]) : card.tags,
      creator: card.creator,
      characterBook: card.characterBook,
      id: card.id,
    );
  }

  /// 把翻译结果写回已入库角色（编辑页「应用译文」用）。
  Future<void> applyTo(CardTranslation translation, CharacterCard card) async {
    if (card.id.isEmpty) return;
    await TranslationStore.saveOriginalCard(card.id, card);
    await TranslationStore.saveCard(card.id, translation);
  }
}

/// 把一条「A, B, C」译文拆回标签列表（容忍中英文逗号/顿号/分号）。
List<String> splitTags(String raw) => [
      for (final part in raw.split(RegExp(r'[,，、;；\n]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
