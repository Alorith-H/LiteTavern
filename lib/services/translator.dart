// 翻译服务：优先走免费公开接口，都不可用时由调用方决定是否改用
// 设置里已配置模型的额度（需先向用户报价）。
//
// 免费源实测（2026-11）：
// - MyMemory（api.mymemory.translated.net）：免 key、支持 Autodetect，
//   单次请求上限 500 字符，匿名日额度约 5k 字符 —— 主源。
// - Google 免费端点（translate.googleapis.com/translate_a/single）：免 key，
//   但可能被限流（429）—— 备源。
// 其余 LibreTranslate 公共镜像、lingva 等均已失效/超时，不再尝试。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'prompt_builder.dart';
import 'sampling_params.dart';
import 'storage.dart';
import 'token_estimate.dart';

/// 单个翻译源失败（可换源重试）。
class TranslationFailure implements Exception {
  final String message;

  /// 免费额度用尽 / 被限流：换源或改用模型。
  final bool quotaExceeded;

  const TranslationFailure(this.message, {this.quotaExceeded = false});

  @override
  String toString() => message;
}

/// 所有免费源都不可用 —— 调用方应问用户是否用模型额度，
/// 并展示 [estimatedTokens] 作为预估消耗。
class TranslationUnavailable implements Exception {
  final String message;
  final int estimatedTokens;

  const TranslationUnavailable(this.message, {required this.estimatedTokens});

  @override
  String toString() => message;
}

class TranslationResult {
  final String text;

  /// 实际干活的源（MyMemory（免费） / Google（免费） / 设置中的模型）。
  final String provider;

  const TranslationResult(this.text, this.provider);
}

abstract class TranslationProvider {
  const TranslationProvider();

  /// 稳定标识（用于缓存/UI 判断）。
  String get id;

  /// 给用户看的名字。
  String get label;

  /// 是否免费（免费源失败会自动串下一个；付费/模型源必须用户确认后才用）。
  bool get isFree;

  Future<String> translate(String text, {String target = 'zh-CN'});
}

/// 文本是否像中文（CJK 字符占比 ≥ [ratio]；短文本按 1 个字也算）。
///
/// 用于「下载到非中文角色卡 → 询问是否翻译」的判定。
bool looksChinese(String text, {double ratio = 0.25}) {
  var cjk = 0;
  var total = 0;
  for (final r in text.runes) {
    if (r == 0x20 || r == 0x0A || r == 0x0D || r == 0x09) continue;
    total++;
    if (_isCjk(r)) cjk++;
  }
  if (total == 0) return false;
  if (total <= 2) return cjk == total;
  return cjk / total >= ratio;
}

bool _isCjk(int r) =>
    (r >= 0x3000 && r <= 0x303F) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0xFF00 && r <= 0xFFEF) ||
    r >= 0x20000;

/// 把长文本切成 ≤ [max] 个 UTF-16 单元的段落（优先在句末/换行处切）。
///
/// MyMemory 单次上限 500 字符，这里默认 450，留出 URL 编码余量。
List<String> splitForTranslation(String text, {int max = 450}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const <String>[];
  if (trimmed.length <= max) return [trimmed];
  final chunks = <String>[];
  final buf = StringBuffer();
  var bufLen = 0;

  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) chunks.add(s);
    buf.clear();
    bufLen = 0;
  }

  final sentences = trimmed.split(RegExp(r'(?<=[。！？!?；;\n])'));
  for (final sentence in sentences) {
    if (sentence.isEmpty) continue;
    if (sentence.length > max) {
      flush();
      // 单个超长句：硬切
      for (var i = 0; i < sentence.length; i += max) {
        final end = (i + max) < sentence.length ? i + max : sentence.length;
        chunks.add(sentence.substring(i, end));
      }
      continue;
    }
    if (bufLen + sentence.length > max) flush();
    buf.write(sentence);
    bufLen += sentence.length;
  }
  flush();
  return chunks;
}

/// MyMemory 免费翻译（主源）。
class MyMemoryProvider extends TranslationProvider {
  final http.Client? client;
  final Duration timeout;

  const MyMemoryProvider({this.client, this.timeout = const Duration(seconds: 20)});

  @override
  String get id => 'mymemory';

  @override
  String get label => 'MyMemory（免费）';

  @override
  bool get isFree => true;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async {
    final chunks = splitForTranslation(text);
    if (chunks.isEmpty) return '';
    final out = StringBuffer();
    for (var i = 0; i < chunks.length; i++) {
      if (i > 0) out.write('\n');
      out.write(await _one(chunks[i], target));
    }
    return out.toString();
  }

  Future<String> _one(String chunk, String target) async {
    final lang = target.replaceAll('-', '-') == 'zh' ? 'zh-CN' : target;
    final uri = Uri.https('api.mymemory.translated.net', '/get', {
      'q': chunk,
      'langpair': 'Autodetect|$lang',
    });
    final http.Response resp;
    try {
      resp = client == null
          ? await http.get(uri).timeout(timeout)
          : await client!.get(uri).timeout(timeout);
    } on TimeoutException {
      throw const TranslationFailure('MyMemory 超时', quotaExceeded: false);
    } catch (e) {
      throw TranslationFailure('MyMemory 网络错误：$e');
    }
    if (resp.statusCode == 429) {
      throw const TranslationFailure('MyMemory 被限流（429）', quotaExceeded: true);
    }
    if (resp.statusCode != 200) {
      throw TranslationFailure('MyMemory 返回 HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const TranslationFailure('MyMemory 返回数据异常');
    }
    final data = json['responseData'];
    final raw = data is Map ? (data['translatedText'] ?? '').toString() : '';
    final t = _unescapeHtml(raw).trim();
    if (t.isEmpty) throw const TranslationFailure('MyMemory 返回空译文');
    if (json['quotaFinished'] == true ||
        t.contains('MYMEMORY WARNING') ||
        t.contains('QUERY LENGTH LIMIT EXCEEDED') ||
        t.startsWith('INVALID ')) {
      throw TranslationFailure('MyMemory 免费额度已用尽：$t', quotaExceeded: true);
    }
    return t;
  }
}

/// Google 免费端点（备源；常被限流）。
class GoogleFreeProvider extends TranslationProvider {
  final http.Client? client;
  final Duration timeout;

  const GoogleFreeProvider({this.client, this.timeout = const Duration(seconds: 15)});

  @override
  String get id => 'google';

  @override
  String get label => 'Google（免费）';

  @override
  bool get isFree => true;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async {
    if (text.trim().isEmpty) return '';
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': target,
      'dt': 't',
      'q': text,
    });
    final http.Response resp;
    try {
      resp = client == null
          ? await http.get(uri).timeout(timeout)
          : await client!.get(uri).timeout(timeout);
    } on TimeoutException {
      throw const TranslationFailure('Google 翻译超时');
    } catch (e) {
      throw TranslationFailure('Google 翻译网络错误：$e');
    }
    if (resp.statusCode == 429) {
      throw const TranslationFailure('Google 免费端点被限流（429）', quotaExceeded: true);
    }
    if (resp.statusCode != 200) {
      throw TranslationFailure('Google 翻译返回 HTTP ${resp.statusCode}');
    }
    try {
      final dynamic data = jsonDecode(utf8.decode(resp.bodyBytes));
      final segs = (data is List && data.isNotEmpty) ? data.first : null;
      if (segs is List) {
        final buf = StringBuffer();
        for (final seg in segs) {
          if (seg is List && seg.isNotEmpty) buf.write(seg.first ?? '');
        }
        final t = buf.toString().trim();
        if (t.isNotEmpty) return t;
      }
      throw const TranslationFailure('Google 翻译返回数据异常');
    } on TranslationFailure {
      rethrow;
    } catch (_) {
      throw const TranslationFailure('Google 翻译返回数据异常');
    }
  }
}

/// 用设置里已配置的模型翻译（消耗 token，必须用户确认后调用）。
class LlmTranslationProvider extends TranslationProvider {
  const LlmTranslationProvider();

  @override
  String get id => 'llm';

  @override
  String get label => '设置中的模型';

  @override
  bool get isFree => false;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    if (AppSettings.baseUrl.isEmpty || AppSettings.model.isEmpty) {
      throw const TranslationFailure('还没有配置模型 API');
    }
    final client = ApiClient();
    final buf = StringBuffer();
    Object? err;
    try {
      await client.streamChat(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
        messages: [
          const PromptMessage(
            role: 'system',
            content: '你是一名专业的翻译。只输出译文本身：不要解释、不要加引号、'
                '不要保留原文、不要分段空行以外的格式。保留原文的换行结构。',
          ),
          PromptMessage(
            role: 'user',
            content: '把下面的文本翻译成简体中文：\n\n$trimmed',
          ),
        ],
        temperature: 0.2,
        topP: 1.0,
        maxTokens: 0,
        stream: false,
        sampling: const SamplingParams(),
        onDelta: buf.write,
        onError: (e) => err = e,
        onDone: () {},
        onUsage: (_, _) {},
      );
    } finally {
      client.dispose();
    }
    if (err != null) throw TranslationFailure('模型翻译失败：$err');
    final out = buf.toString().trim();
    if (out.isEmpty) throw const TranslationFailure('模型没有返回译文');
    return out;
  }
}

/// 翻译调度：免费源按顺序尝试（记住上次成功的源），全挂后可选择用模型。
class TranslationService {
  final List<TranslationProvider> freeProviders;
  /// 模型翻译源（默认 [LlmTranslationProvider]，测试可注入替身）。
  final TranslationProvider llm;

  /// 上次成功的免费源下标 —— 下次优先用它，避免每次都先踩一次超时。
  int _preferred = 0;

  TranslationService({
    List<TranslationProvider>? freeProviders,
    TranslationProvider? llm,
  })  : freeProviders = freeProviders ??
            const <TranslationProvider>[MyMemoryProvider(), GoogleFreeProvider()],
        llm = llm ?? const LlmTranslationProvider();

  /// 只试免费源；全失败返回 null（不抛异常，供 UI 静默降级）。
  Future<TranslationResult?> tryFree(String text, {String target = 'zh-CN'}) async {
    if (text.trim().isEmpty) return const TranslationResult('', 'none');
    final order = <int>[
      for (var i = 0; i < freeProviders.length; i++) i,
    ]..sort((a, b) => (a == _preferred ? -1 : b == _preferred ? 1 : a - b));
    for (final idx in order) {
      final p = freeProviders[idx];
      try {
        final t = await p.translate(text, target: target);
        if (t.trim().isNotEmpty) {
          _preferred = idx;
          return TranslationResult(t, p.label);
        }
      } catch (_) {
        // 换下一个源
      }
    }
    return null;
  }

  /// 批量翻译（同一源连续翻，减少试探开销）。
  Future<List<TranslationResult>> translateAll(
    List<String> texts, {
    String target = 'zh-CN',
    bool allowLlm = false,
  }) async {
    final errors = <String>[];
    final order = <int>[
      for (var i = 0; i < freeProviders.length; i++) i,
    ]..sort((a, b) => (a == _preferred ? -1 : b == _preferred ? 1 : a - b));
    for (final idx in order) {
      final p = freeProviders[idx];
      try {
        final out = <TranslationResult>[];
        for (final text in texts) {
          out.add(TranslationResult(await p.translate(text, target: target), p.label));
        }
        _preferred = idx;
        return out;
      } catch (e) {
        errors.add('${p.label}：$e');
      }
    }
    if (allowLlm) {
      try {
        final out = <TranslationResult>[];
        for (final text in texts) {
          out.add(TranslationResult(await llm.translate(text, target: target), llm.label));
        }
        return out;
      } catch (e) {
        errors.add('${llm.label}：$e');
      }
    }
    throw TranslationUnavailable(
      errors.isEmpty ? '免费翻译暂不可用' : '免费翻译不可用（${errors.join('；')}）',
      estimatedTokens: estimateTranslationTokens(texts),
    );
  }

  /// 估算把这些文本用模型翻译要花多少 token（输入 + 输出 + 指令开销）。
  static int estimateTranslationTokens(Iterable<String> texts) {
    final joined = texts.where((t) => t.trim().isNotEmpty).join('\n');
    if (joined.isEmpty) return 0;
    final input = estimateTokens(joined);
    // 输出中文通常与输入 token 同量级，另加系统指令/格式开销
    return input * 2 + 120;
  }
}

/// 解开 MyMemory 返回里的 HTML 实体（它会把引号/撇号转义）。
String _unescapeHtml(String s) {
  var out = s;
  const map = <String, String>{
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&nbsp;': ' ',
  };
  for (final e in map.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  return out
      .replaceAll('&#10;', '\n')
      .replaceAll('&lt;br /&gt;', '\n')
      .replaceAll('&lt;br&gt;', '\n');
}
