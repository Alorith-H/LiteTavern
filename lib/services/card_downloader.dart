import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 下载失败（message 为可直接展示的中文原因）。
class CardDownloadException implements Exception {
  final String message;
  const CardDownloadException(this.message);

  @override
  String toString() => message;
}

/// 最大下载 50MB（流式累计，超限即中断）。
const int _maxDownloadBytes = 50 * 1024 * 1024;

/// 从 http/https 链接下载角色卡原始字节。
/// - 跟随重定向
/// - 30 秒超时（连接与流式读取）
/// - 最大 50MB 流式限制
Future<Uint8List> downloadCard(String rawUrl) async {
  final url = rawUrl.trim();
  final uri = Uri.tryParse(url);
  if (url.isEmpty || uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw const CardDownloadException('请输入有效的 http/https 链接');
  }

  final client = http.Client();
  try {
    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5;
    final response =
        await client.send(request).timeout(const Duration(seconds: 30));

    if (response.statusCode == 404) {
      throw const CardDownloadException('下载失败：404，未找到文件');
    }
    if (response.statusCode != 200) {
      throw CardDownloadException('下载失败：HTTP ${response.statusCode}');
    }

    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 30))) {
      total += chunk.length;
      if (total > _maxDownloadBytes) {
        throw const CardDownloadException('下载失败：文件超过 50MB 限制');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  } on TimeoutException {
    throw const CardDownloadException('下载超时（30 秒），请检查链接或网络');
  } on http.ClientException catch (e) {
    throw CardDownloadException('网络错误：${e.message}');
  } on SocketException catch (e) {
    throw CardDownloadException('网络错误：${e.message}');
  } finally {
    client.close();
  }
}
