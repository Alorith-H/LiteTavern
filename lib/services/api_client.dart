import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'prompt_builder.dart';

/// OpenAI 兼容 API 流式客户端（支持取消）。
class ApiClient {
  http.Client? _client;
  bool _cancelled = false;

  /// 流式聊天。回调逐 chunk 收到 delta 文本；
  /// provider 返回 usage 时（[DONE] 前最后一个 chunk）回调 [onUsage]。
  Future<void> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<PromptMessage> messages,
    double temperature = 0.8,
    double topP = 1.0,
    int maxTokens = 0,
    required void Function(String delta) onDelta,
    required void Function(String error) onError,
    required void Function() onDone,
    void Function(int promptTokens, int completionTokens)? onUsage,
  }) async {
    cancel();
    _cancelled = false;
    final client = http.Client();
    _client = client;

    try {
      final uri = Uri.parse('${_trimSlash(baseUrl)}/chat/completions');

      Map<String, dynamic> buildBody(bool includeUsage) => {
            'model': model,
            'messages': messages.map((m) => m.toJson()).toList(),
            'stream': true,
            'temperature': temperature,
            'top_p': topP,
            if (maxTokens > 0) 'max_tokens': maxTokens,
            if (includeUsage) 'stream_options': {'include_usage': true},
          };

      // 请求带 stream_options 收集 usage；若 provider 因该字段报 400，
      // 去掉后静默重试一次（不弹错误给用户）。
      var includeUsage = true;
      late final http.StreamedResponse response;
      while (true) {
        final request = http.Request('POST', uri);
        request.headers['Content-Type'] = 'application/json';
        request.headers['Authorization'] = 'Bearer $apiKey';
        request.body = jsonEncode(buildBody(includeUsage));
        final r = await client
            .send(request)
            .timeout(const Duration(seconds: 15));
        if (_cancelled) return;
        if (r.statusCode == 400 && includeUsage) {
          includeUsage = false;
          try {
            await r.stream.drain<void>();
          } catch (_) {
            // 丢弃报错响应体，直接重试
          }
          continue;
        }
        response = r;
        break;
      }

      if (response.statusCode != 200) {
        if (_cancelled) return;
        final body = await response.stream.bytesToString();
        onError(humanError(response.statusCode, body));
        return;
      }

      int? usagePrompt;
      int? usageCompletion;

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (_cancelled) break;
        if (!line.startsWith('data:')) continue;
        var data = line.substring(5).trim();
        if (data.startsWith('[')) {
          // data: [DONE]
          if (data == '[DONE]') break;
        }
        try {
          final json = jsonDecode(data);
          if (json is Map) {
            // 收集带 usage 的 chunk（通常在 [DONE] 前最后一个）
            final usage = json['usage'];
            if (usage is Map) {
              final p = usage['prompt_tokens'];
              final c = usage['completion_tokens'];
              if (p is num && c is num) {
                usagePrompt = p.toInt();
                usageCompletion = c.toInt();
              }
            }
            final choices = json['choices'];
            if (choices is List && choices.isNotEmpty) {
              final first = choices.first;
              final delta = first is Map ? first['delta'] : null;
              final content = delta is Map ? delta['content'] : null;
              if (content is String && content.isNotEmpty) {
                onDelta(content);
              }
            }
          }
        } catch (_) {
          // 忽略无法解析的行（如注释行、半包）
        }
      }
      if (!_cancelled) {
        if (usagePrompt != null && usageCompletion != null) {
          onUsage?.call(usagePrompt, usageCompletion);
        }
        onDone();
      }
    } on TimeoutException {
      if (!_cancelled) onError('连接超时（15 秒），请检查网络或 Base URL');
    } catch (e) {
      if (!_cancelled) {
        if (e is http.ClientException) {
          onError('网络错误：${e.message}（请检查地址和网络）');
        } else {
          onError('请求失败：$e');
        }
      }
    } finally {
      if (identical(_client, client)) _client = null;
      client.close();
    }
  }

  /// 生成长对话摘要（v0.6.0）。流式收集但不做 UI 逐字刷新，
  /// 返回完整文本；被 [cancel] 取消时返回 ''。
  /// 复用同一套 API 配置，temperature 由调用方传（建议 0.4）。
  Future<String> summarize({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.4,
    int maxTokens = 512,
  }) async {
    cancel();
    _cancelled = false;
    final client = http.Client();
    _client = client;

    try {
      final uri = Uri.parse('${_trimSlash(baseUrl)}/chat/completions');
      final request = http.Request('POST', uri);
      request.headers['Content-Type'] = 'application/json';
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'stream': true,
        'temperature': temperature,
        'max_tokens': maxTokens,
      });
      final response =
          await client.send(request).timeout(const Duration(seconds: 15));
      if (_cancelled) return '';

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        if (_cancelled) return '';
        throw ApiException(humanError(response.statusCode, body));
      }

      final buf = StringBuffer();
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (_cancelled) break;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data);
          if (json is! Map) continue;
          final choices = json['choices'];
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            final delta = first is Map ? first['delta'] : null;
            final content = delta is Map ? delta['content'] : null;
            if (content is String && content.isNotEmpty) {
              buf.write(content);
            }
          }
        } catch (_) {
          // 忽略无法解析的行
        }
      }
      return _cancelled ? '' : buf.toString();
    } on TimeoutException {
      if (_cancelled) return '';
      throw const ApiException('连接超时（15 秒），请检查网络或 Base URL');
    } catch (e) {
      if (_cancelled) return '';
      if (e is ApiException) rethrow;
      if (e is http.ClientException) {
        throw ApiException('网络错误：${e.message}（请检查地址和网络）');
      }
      throw ApiException('请求失败：$e');
    } finally {
      if (identical(_client, client)) _client = null;
      client.close();
    }
  }

  /// 取消当前请求：关闭底层连接。已收到的文本由 UI 保留。
  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  void dispose() => cancel();

  /// 测试连接：发一条 hi，成功返回模型名。
  Future<String> testConnection({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final uri = Uri.parse('${_trimSlash(baseUrl)}/chat/completions');
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'hi'}
            ],
            'stream': false,
            'max_tokens': 1,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw ApiException(humanError(response.statusCode, response.body));
    }
    try {
      final json = jsonDecode(response.body);
      final m = json is Map ? json['model'] : null;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return model;
  }

  static String _trimSlash(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  /// 非 200 → 中文可读错误。
  static String humanError(int code, String body) {
    if (code == 401 || code == 403) {
      return 'API Key 无效或无权限（$code），请检查密钥';
    }
    if (code == 404) {
      return '接口地址错误（404），请检查 Base URL';
    }
    if (code == 429) {
      return '请求过于频繁或额度不足（429）';
    }
    if (code >= 500) return '服务端错误（$code），请稍后再试';
    var detail = body;
    try {
      final json = jsonDecode(body);
      final err = json is Map ? json['error'] : null;
      if (err is Map && err['message'] is String) {
        detail = err['message'] as String;
      }
    } catch (_) {}
    if (detail.length > 200) detail = '${detail.substring(0, 200)}…';
    return '请求失败（$code）：$detail';
  }
}

/// 带中文消息的 API 异常。
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}
