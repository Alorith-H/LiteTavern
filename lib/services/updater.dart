import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_info.dart';

/// 一个新版本的信息（来自 GitHub Releases）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    required this.pageUrl,
    this.publishedAt,
  });

  /// 去掉前缀 v 的版本号，例如 `0.23.0`。
  final String version;

  /// 原始 tag，例如 `v0.23.0`。
  final String tag;

  /// 发布说明（markdown）。
  final String notes;

  /// APK 下载地址；发布里没有 APK 附件时为空串。
  final String apkUrl;

  /// APK 字节数；未知为 0。
  final int apkSize;

  /// Release 页面地址。
  final String pageUrl;

  final DateTime? publishedAt;

  bool get hasApk => apkUrl.isNotEmpty;

  /// 人类可读的大小，例如 `59.3 MB`。
  String get apkSizeLabel => formatBytes(apkSize);
}

/// 检查更新失败。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `59.3 MB` 这类文案。
String formatBytes(int bytes) {
  if (bytes <= 0) return '未知大小';
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value >= 100 ? 0 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// 去掉前缀 `v` / `V`，去空白。
String normalizeVersion(String raw) =>
    raw.trim().replaceFirst(RegExp(r'^[vV]'), '').trim();

/// 把版本号解析成数字段（非数字部分忽略，最多 4 段）。
List<int> _versionNumbers(String raw) {
  final normalized = normalizeVersion(raw);
  final parts = normalized.split('.');
  final numbers = <int>[];
  for (final part in parts) {
    final match = RegExp(r'^\d+').firstMatch(part);
    numbers.add(match == null ? 0 : int.parse(match.group(0)!));
  }
  while (numbers.length < 3) {
    numbers.add(0);
  }
  return numbers;
}

/// 比较两个版本号：a > b 返回正数，相等返回 0，a < b 返回负数。
///
/// 只比较数字段（`0.23.0-beta` 等同 `0.23.0`），避免发布 tag 带后缀时判断混乱。
int compareVersions(String a, String b) {
  final left = _versionNumbers(a);
  final right = _versionNumbers(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l > r ? 1 : -1;
  }
  return 0;
}

/// 检查更新：读 GitHub Releases 的 latest，比较版本、取 APK 附件。
///
/// 纯本机逻辑，不引入新依赖；网络失败抛 [UpdateCheckException]（中文文案）。
class UpdateService {
  UpdateService({http.Client? client, this.repo = 'Alorith-H/LiteTavern'})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String repo;

  static const Duration _timeout = Duration(seconds: 20);

  /// APK 下载上限（防止异常响应把手机写满）。
  static const int maxApkBytes = 300 * 1024 * 1024;

  Uri get latestReleaseUri =>
      Uri.parse('https://api.github.com/repos/$repo/releases/latest');

  /// 有新版返回 [UpdateInfo]，已是最新返回 null。
  Future<UpdateInfo?> checkForUpdate({String currentVersion = kAppVersion}) async {
    http.Response response;
    try {
      response = await _client.get(
        latestReleaseUri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'LiteTavern',
        },
      ).timeout(_timeout);
    } on TimeoutException {
      throw const UpdateCheckException('检查更新超时，请检查网络后重试');
    } on UpdateCheckException {
      rethrow;
    } catch (e) {
      throw UpdateCheckException('检查更新失败：$e');
    }

    if (response.statusCode == 404) {
      throw const UpdateCheckException('还没有发布过版本');
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException('请求太频繁了，过一会儿再试');
    }
    if (response.statusCode != 200) {
      throw UpdateCheckException('检查更新失败（HTTP ${response.statusCode}）');
    }
    return parseRelease(response.body, currentVersion: currentVersion);
  }

  /// 解析 `/releases/latest` 的 JSON。纯函数，便于单测。
  static UpdateInfo? parseRelease(
    String body, {
    required String currentVersion,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const UpdateCheckException('更新信息格式不对，稍后再试');
    }
    if (decoded is! Map) {
      throw const UpdateCheckException('更新信息格式不对，稍后再试');
    }
    final json = decoded.cast<String, Object?>();

    if (json['draft'] == true || json['prerelease'] == true) return null;

    final tag = (json['tag_name'] as String?)?.trim() ?? '';
    if (tag.isEmpty) return null;
    final version = normalizeVersion(tag);
    if (compareVersions(version, currentVersion) <= 0) return null;

    var apkUrl = '';
    var apkSize = 0;
    final assets = json['assets'];
    if (assets is List) {
      Map? best;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = (asset['name'] as String?)?.toLowerCase() ?? '';
        if (!name.endsWith('.apk')) continue;
        if (name == 'app-release.apk') {
          best = asset;
          break;
        }
        best ??= asset;
      }
      if (best != null) {
        apkUrl = (best['browser_download_url'] as String?) ?? '';
        final size = best['size'];
        if (size is int && size > 0) {
          apkSize = size;
        } else if (size is num) {
          apkSize = size.toInt();
        }
      }
    }

    final publishedRaw = (json['published_at'] as String?)?.trim() ?? '';
    return UpdateInfo(
      version: version,
      tag: tag,
      notes: (json['body'] as String?) ?? '',
      apkUrl: apkUrl,
      apkSize: apkSize,
      pageUrl: (json['html_url'] as String?) ?? '',
      publishedAt:
          publishedRaw.isEmpty ? null : DateTime.tryParse(publishedRaw),
    );
  }

  /// 下载 APK 到 [dir]，返回落盘的文件。
  ///
  /// [isCancelled] 每读一块都会问一次；返回 true 时中止并删掉半成品。
  Future<File> downloadApk(
    UpdateInfo info, {
    required Directory dir,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!info.hasApk) {
      throw const UpdateCheckException('这个版本没有提供 APK 附件');
    }
    await dir.create(recursive: true);
    final safeName = info.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final target = File('${dir.path}${Platform.pathSeparator}LiteTavern-$safeName.apk');

    final request = http.Request('GET', Uri.parse(info.apkUrl))
      ..headers['User-Agent'] = 'LiteTavern';

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const UpdateCheckException('下载超时，请检查网络后重试');
    } catch (e) {
      throw UpdateCheckException('下载失败：$e');
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw UpdateCheckException('下载失败（HTTP ${response.statusCode}）');
    }

    final declared = response.contentLength;
    final total = declared != null && declared > 0
        ? declared
        : (info.apkSize > 0 ? info.apkSize : null);
    if (total != null && total > maxApkBytes) {
      throw const UpdateCheckException('安装包太大，已中止下载');
    }

    final sink = target.openWrite();
    var received = 0;
    var lastReported = -1;
    var cancelled = false;
    try {
      onProgress?.call(0, total);
      await for (final chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        received += chunk.length;
        if (received > maxApkBytes) {
          throw const UpdateCheckException('安装包太大，已中止下载');
        }
        sink.add(chunk);
        // 每 2% 或 256KB 上报一次，避免刷屏
        final step = total == null || total <= 0
            ? 256 * 1024
            : (total / 50).clamp(64 * 1024, 2 * 1024 * 1024);
        if (received - lastReported >= step || received == total) {
          lastReported = received;
          onProgress?.call(received, total);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (cancelled) {
      await target.delete().catchError((_) => target);
      throw const UpdateCheckException('已取消下载');
    }
    if (received == 0) {
      await target.delete().catchError((_) => target);
      throw const UpdateCheckException('下载到的文件是空的，稍后再试');
    }
    return target;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
