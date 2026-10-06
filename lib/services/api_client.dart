import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'prompt_builder.dart';

/// OpenAI 兼容 API 流式客户端（支持取消）。
class ApiClient {
  http.Client? _client;
  bool _cancelled = false;

  /// 流式聊天。回调逐 chunk 收到 delta 文本。
  Future<void> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<PromptMessage> messages,
    double temperature = 0.8,
    required void Function(String delta) onDelta,
    required void Function(String error) onError,
    required void Function() onDone,
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
        'messages': messages.map((m) => m.toJson()).toList(),
        'stream': true,
        'temperature': temperature,
      });

      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        if (_cancelled) return;
        final body = await response.stream.bytesToString();
        onError(humanError(response.statusCode, body));
        return;
      }

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
          final choices = json is Map ? json['choices'] : null;
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            final delta = first is Map ? first['delta'] : null;
            final content = delta is Map ? delta['content'] : null;
            if (content is String && content.isNotEmpty) {
              onDelta(content);
            }
          }
        } catch (_) {
          // 忽略无法解析的行（如注释行、半包）
        }
      }
      if (!_cancelled) onDone();
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
