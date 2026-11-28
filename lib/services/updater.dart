import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_info.dart';
import 'storage.dart';

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


/// 一个候选下载源。
class DownloadSource {
  const DownloadSource(this.label, this.url);

  final String label;
  final String url;

  @override
  String toString() => '$label（$url）';
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

  /// 内置的公共加速镜像（把 GitHub 原始地址拼在结尾）。
  ///
  /// 这些是社区镜像，随时可能失效；所以每次下载都会先测速，
  /// 只把响应的源排进候选，全挂了再回落到直连。
  /// 公共加速镜像。只放实测能通的：2026-11 实测 hub.gitmirror.com 域名解析失败、
  /// github.moeyy.xyz 连接超时，已去掉，免得每次测速都白等一轮。
  static const Map<String, String> mirrorPrefixes = {
    'ghfast': 'https://ghfast.top/',
    'gh-proxy': 'https://gh-proxy.com/',
    'ghproxy.imciel': 'https://ghproxy.imciel.com/',
    'ghproxy.net': 'https://ghproxy.net/',
  };

  /// 按设置拼出候选下载源列表（第一个是首选）。
  ///
  /// 纯函数，方便单测：GitHub 直连永远在列表里，`custom` 模式会把它排到最后。
  static List<DownloadSource> downloadSourcesFor(
    String apkUrl, {
    UpdateSourceMode mode = UpdateSourceMode.auto,
    String customPrefix = '',
  }) {
    final raw = apkUrl.trim();
    if (raw.isEmpty) return const [];
    final direct = DownloadSource('GitHub 直连', raw);
    final custom = customPrefix.trim();
    String withPrefix(String prefix) {
      final base = prefix.endsWith('/') ? prefix : '$prefix/';
      return '$base$raw';
    }

    switch (mode) {
      case UpdateSourceMode.githubOnly:
        return [direct];
      case UpdateSourceMode.custom:
        return [
          if (custom.isNotEmpty) DownloadSource('自定义源', withPrefix(custom)),
          direct,
        ];
      case UpdateSourceMode.auto:
        return [
          if (custom.isNotEmpty) DownloadSource('自定义源', withPrefix(custom)),
          direct,
          for (final entry in mirrorPrefixes.entries)
            DownloadSource('加速镜像·${entry.key}', withPrefix(entry.value)),
        ];
    }
  }

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
  /// 行为：
  /// * 按 [AppSettings.updateSourceMode] 拼候选源，先并行测速（只读 64KB）再挑最快的；
  /// * 下到一半断了/换源，会用 `Range` 从已下载的位置续传（`.part` 文件）；
  /// * 取消下载时保留 `.part`，下次接着下；
  /// * 所有源都失败才抛错，错误里带上试过的源。
  Future<File> downloadApk(
    UpdateInfo info, {
    required Directory dir,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
    void Function(DownloadSource source)? onSource,
    void Function(double bytesPerSecond)? onSpeed,
  }) async {
    if (!info.hasApk) {
      throw const UpdateCheckException('这个版本没有提供 APK 附件');
    }
    await dir.create(recursive: true);
    final safeName = info.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final target = File('${dir.path}${Platform.pathSeparator}LiteTavern-$safeName.apk');
    final part = File('${target.path}.part');
    final expected = info.apkSize > 0 ? info.apkSize : 0;

    // 0) 之前已经下完（比如上次卡在「允许安装应用」那一步）就直接复用，不再重下。
    if (expected > 0) {
      if (await target.exists() && await target.length() == expected) {
        onProgress?.call(expected, expected);
        return target;
      }
      if (!await target.exists() &&
          await part.exists() &&
          await part.length() == expected) {
        onProgress?.call(expected, expected);
        return part.rename(target.path);
      }
    }

    final candidates = downloadSourcesFor(
      info.apkUrl,
      mode: AppSettings.updateSourceMode,
      customPrefix: AppSettings.updateCustomMirror,
    );
    if (candidates.isEmpty) {
      throw const UpdateCheckException('这个版本没有提供 APK 附件');
    }

    // 1) 并行测速：只读响应开头，超时/报错的源直接排除。
    final probes = await Future.wait(
      candidates.take(6).map((source) => _probe(source, isCancelled: isCancelled)),
    );
    final ranked = probes.whereType<_Probe>().toList()
      ..sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
    final ordered = <DownloadSource>[
      for (final probe in ranked) probe.source,
      for (final source in candidates)
        if (!ranked.any((probe) => probe.source.url == source.url)) source,
    ];

    // 2) 依次尝试，失败自动换源；每个源都从 .part 当前位置续传。
    Object? lastError;
    var reportedSource = '';
    for (final source in ordered) {
      if (isCancelled?.call() ?? false) {
        throw const UpdateCheckException('已取消下载');
      }
      if (reportedSource != source.label) {
        reportedSource = source.label;
        onSource?.call(source);
      }
      var received = await part.exists() ? await part.length() : 0;
      if (expected > 0 && received > expected) {
        // 残留的半成品比目标还大，说明是别的版本，重下。
        await part.delete();
        received = 0;
      }
      if (expected > 0 && received == expected) break; // 已经下完了
      onProgress?.call(received, expected > 0 ? expected : null);
      try {
        await _downloadFrom(
          source,
          part,
          start: received,
          expected: expected,
          onProgress: (got, total) {
            onProgress?.call(got, expected > 0 ? expected : total);
          },
          onSpeed: onSpeed,
          isCancelled: isCancelled,
        );
        final length = await part.length();
        if (expected > 0 && length < expected) {
          throw UpdateCheckException(
            '${source.label} 连接中断（/ 字节）',
          );
        }
        if (length > 0) {
          lastError = null;
          break;
        }
      } on UpdateCheckException catch (e) {
        if (e.message == '已取消下载') rethrow;
        lastError = e;
      } catch (e) {
        lastError = UpdateCheckException('${source.label} 下载失败：$e');
      }
    }

    if (isCancelled?.call() ?? false) {
      throw const UpdateCheckException('已取消下载');
    }
    if (!await part.exists()) {
      throw UpdateCheckException(
        lastError == null ? '下载失败，稍后再试' : '下载失败：${_messageOf(lastError)}',
      );
    }
    final downloaded = await part.length();
    if (downloaded == 0) {
      throw const UpdateCheckException('下载到的文件是空的，稍后再试');
    }
    if (expected > 0 && downloaded < expected) {
      throw UpdateCheckException(
        '下载不完整（/ 字节），已下载的部分会保留，重试会接着下',
      );
    }
    if (lastError != null) {
      throw UpdateCheckException('下载失败：${_messageOf(lastError)}');
    }
    if (await target.exists()) await target.delete();
    return part.rename(target.path);
  }

  /// 从 [source] 把数据追加到 [part]（[start] > 0 时用 Range 续传）。
  Future<void> _downloadFrom(
    DownloadSource source,
    File part, {
    required int start,
    required int expected,
    required void Function(int received, int? total) onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    bool Function()? isCancelled,
  }) async {
    final request = http.Request('GET', Uri.parse(source.url))
      ..headers['User-Agent'] = 'LiteTavern';
    if (start > 0) request.headers['Range'] = 'bytes=$start-';

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const UpdateCheckException('连接超时');
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw UpdateCheckException('HTTP ${response.statusCode}');
    }
    // 服务器不认 Range、直接回整包：丢掉半成品，从头写。
    final restart = response.statusCode == 200 && start > 0;

    final declared = response.contentLength;
    final total = expected > 0 ? expected : declared;

    final sink = part.openWrite(mode: restart ? FileMode.write : FileMode.append);
    var received = restart ? 0 : start;
    var lastReported = -1;
    final stopwatch = Stopwatch()..start();
    var speedWindowBytes = 0;
    var speedWindowStart = stopwatch.elapsedMicroseconds;
    var cancelled = false;

    try {
      onProgress(received, total);
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

        speedWindowBytes += chunk.length;
        final windowMicros = stopwatch.elapsedMicroseconds - speedWindowStart;
        if (windowMicros >= 400 * 1000) {
          final bytesPerSecond = speedWindowBytes / (windowMicros / 1000000);
          onSpeed?.call(bytesPerSecond);
          speedWindowBytes = 0;
          speedWindowStart = stopwatch.elapsedMicroseconds;
        }

        final step = total == null || total <= 0
            ? 256 * 1024
            : (total / 50).clamp(64 * 1024, 2 * 1024 * 1024);
        if (received - lastReported >= step || received == total) {
          lastReported = received;
          onProgress(received, total);
        }
      }
      await sink.flush();
    } on UpdateCheckException {
      rethrow;
    } catch (e) {
      throw UpdateCheckException('传输中断：$e');
    } finally {
      await sink.close();
    }

    if (cancelled) throw const UpdateCheckException('已取消下载');
  }

  /// 只读每个源开头的一小段，估算速度；失败的源返回 null。
  Future<_Probe?> _probe(
    DownloadSource source, {
    bool Function()? isCancelled,
  }) async {
    final request = http.Request('GET', Uri.parse(source.url))
      ..headers['User-Agent'] = 'LiteTavern'
      ..headers['Range'] = 'bytes=0-65535';
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client.send(request).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 && response.statusCode != 206) return null;
      var got = 0;
      await for (final chunk in response.stream) {
        got += chunk.length;
        if (got >= 32 * 1024) break;
        if (stopwatch.elapsed > const Duration(seconds: 6)) break;
        if (isCancelled?.call() ?? false) break;
      }
      stopwatch.stop();
      final micros = stopwatch.elapsedMicroseconds;
      if (got <= 0 || micros <= 0) return null;
      return _Probe(source, got / (micros / 1000000));
    } catch (_) {
      return null;
    }
  }

  static String _messageOf(Object? error) {
    if (error is UpdateCheckException) return error.message;
    return '$error';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// 测速结果：某个源在前几十 KB 上的吞吐。
class _Probe {
  const _Probe(this.source, this.bytesPerSecond);

  final DownloadSource source;
  final double bytesPerSecond;
}


