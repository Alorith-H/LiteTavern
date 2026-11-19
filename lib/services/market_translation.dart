// 市场条目的翻译编排：取缓存 → 免费源批量翻 → 存缓存。
//
// 展示层只需要：先 [cached]，没有再 [translate]（或先向用户报价再用模型翻）。
import '../models/card_translation.dart';
import 'card_market.dart';
import 'translation_store.dart';
import 'translator.dart';

class MarketTranslationService {
  final TranslationService translator;

  MarketTranslationService({TranslationService? translator})
      : translator = translator ?? TranslationService();

  /// 读本地缓存（列表滚动时先用它，避免重复请求）。
  Future<MarketCardTranslation?> cached(MarketCard card) =>
      TranslationStore.loadMarket(card.fullPath);

  /// 翻一张卡的 名字 / 简介 / 标签，结果写入缓存。
  ///
  /// [allowLlm] = true 才会动模型额度；免费源全挂时抛
  /// [TranslationUnavailable]（带预估 token），调用方据此询问用户。
  Future<MarketCardTranslation> translate(
    MarketCard card, {
    bool allowLlm = false,
  }) async {
    // 三个字段合成一次批量翻译：同一源连续请求，减少试探。
    final fields = <String>[
      card.name,
      card.description,
      card.topics.take(12).join(', '),
    ];
    final filled = <int>[];
    final texts = <String>[];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].trim().isNotEmpty) {
        filled.add(i);
        texts.add(fields[i].trim());
      }
    }
    if (texts.isEmpty) return const MarketCardTranslation();

    final results = await translator.translateAll(texts, allowLlm: allowLlm);
    final out = List<String>.filled(3, '');
    for (var i = 0; i < filled.length && i < results.length; i++) {
      out[filled[i]] = results[i].text.trim();
    }
    final provider = results.isEmpty ? '' : results.first.provider;
    final tags = out[2].isEmpty
        ? const <String>[]
        : splitTranslatedTags(out[2]);
    final translation = MarketCardTranslation(
      name: out[0],
      description: out[1],
      tags: tags,
      provider: provider,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await TranslationStore.saveMarket(card.fullPath, translation);
    return translation;
  }

  /// 用模型翻这一批卡片大概要花多少 token（询问用户时展示）。
  static int estimateTokensFor(Iterable<MarketCard> cards) =>
      TranslationService.estimateTranslationTokens(
        cards.expand((c) => <String>[
          c.name,
          c.description,
          c.topics.take(12).join(', '),
        ]),
      );
}

/// 把一条「A, B, C」译文拆回标签列表（容忍中英文逗号/顿号/分号）。
List<String> splitTranslatedTags(String raw) => [
      for (final part in raw.split(RegExp(r'[,，、;；\n]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
