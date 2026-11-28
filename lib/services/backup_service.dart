// 整库备份与恢复（v0.26.0）。
//
// 一个 .zip 带走：角色卡 + 头像、聊天记录、世界书、群聊、以及全部设置项
// （模型配置、生成预设、人设、翻译 Key、书签、聊天索引……）。
//
// 设计成「收集 → 打包」「解包 → 校验 → 写回」两段纯逻辑，方便单测：
// 不直接依赖 path_provider（文档目录由调用方传入）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../app_info.dart';
import 'storage.dart';

/// 备份/恢复失败（消息可直接展示给用户）。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份包里的 manifest.json。
class BackupManifest {
  const BackupManifest({
    required this.appVersion,
    required this.createdAt,
    required this.fileCount,
    required this.prefCount,
    this.prefs = const <String, Object?>{},
  });

  final String appVersion;
  final DateTime createdAt;
  final int fileCount;
  final int prefCount;
  final Map<String, Object?> prefs;

  Map<String, dynamic> toJson() => {
        'format': BackupService.format,
        'formatVersion': BackupService.formatVersion,
        'appVersion': appVersion,
        'createdAt': createdAt.toIso8601String(),
        'fileCount': fileCount,
        'prefCount': prefCount,
        'prefs': prefs,
      };

  static BackupManifest fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    return BackupManifest(
      appVersion: json['appVersion'] as String? ?? '',
      createdAt: created ?? DateTime.now(),
      fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
      prefCount: (json['prefCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 解包后的备份：清单 + 相对路径 → 字节 + 设置项。
class BackupArchive {
  const BackupArchive({
    required this.manifest,
    required this.files,
    required this.prefs,
  });

  final BackupManifest manifest;
  final Map<String, List<int>> files;
  final Map<String, Object?> prefs;

  /// 备份里某个数据目录（characters / conversations / worldbooks / groups）的文件数。
  int fileCountIn(String dir) =>
      files.keys.where((k) => k.split('/').first == dir).length;
}

/// 恢复时只挑想恢复的部分（v0.38.0）。默认全选，等于旧行为。
class BackupRestoreOptions {
  const BackupRestoreOptions({
    this.characters = true,
    this.conversations = true,
    this.worldBooks = true,
    this.groups = true,
    this.settings = true,
  });

  /// 全选（恢复整包）。
  static const BackupRestoreOptions all = BackupRestoreOptions();

  final bool characters;
  final bool conversations;
  final bool worldBooks;
  final bool groups;
  final bool settings;

  /// 是否至少选了一项。
  bool get any =>
      characters || conversations || worldBooks || groups || settings;

  /// 某个数据目录是否要恢复。
  bool allowsDir(String dir) => switch (dir) {
        'characters' => characters,
        'conversations' => conversations,
        'worldbooks' => worldBooks,
        'groups' => groups,
        _ => false,
      };

  /// 复制一份并改其中一项（弹窗里勾选时用）。
  BackupRestoreOptions copyWith({
    bool? characters,
    bool? conversations,
    bool? worldBooks,
    bool? groups,
    bool? settings,
  }) =>
      BackupRestoreOptions(
        characters: characters ?? this.characters,
        conversations: conversations ?? this.conversations,
        worldBooks: worldBooks ?? this.worldBooks,
        groups: groups ?? this.groups,
        settings: settings ?? this.settings,
      );

  /// 按当前勾选，这份备份实际会恢复多少文件。
  int selectedFileCount(BackupArchive archive) => archive.files.keys
      .where((k) => allowsDir(k.split('/').first))
      .length;

  /// 勾选内容的简短说明（「角色卡 3 + 聊天 2」）。
  String summary(BackupArchive archive) {
    final parts = <String>[
      if (characters) '角色卡 ${archive.fileCountIn('characters')}',
      if (conversations) '聊天 ${archive.fileCountIn('conversations')}',
      if (worldBooks) '世界书 ${archive.fileCountIn('worldbooks')}',
      if (groups) '群聊 ${archive.fileCountIn('groups')}',
      if (settings) '设置 ${archive.prefs.length} 项',
    ];
    return parts.isEmpty ? '什么都没选' : parts.join(' · ');
  }
}

/// 备份 / 恢复。文件层只碰 [Storage.docsDir] 下的四个子目录。
class BackupService {
  BackupService._();

  static const String format = 'litetavern-backup';
  static const int formatVersion = 1;
  static const String manifestName = 'manifest.json';
  static const String filesPrefix = 'files';

  /// 防 zip 炸弹（v0.41.0）：备份包条目数与解压后总大小上限。
  /// 正常整库备份也就几 MB 到几十 MB，超过这些值基本可以断定是坏包或恶意包。
  static const int maxEntries = 20000;
  static const int maxUncompressedBytes = 1024 * 1024 * 1024; // 1GB
  static const int maxSingleFileBytes = 200 * 1024 * 1024; // 200MB

  /// 参与备份的子目录（Storage 里创建的那四个）。
  static const List<String> dataDirs = [
    'characters',
    'conversations',
    'worldbooks',
    'groups',
  ];

  /// 收集文档目录下的数据文件并打包成 zip。
  static Future<Uint8List> createBackup({
    Directory? docs,
    Map<String, Object?>? prefs,
    String appVersion = kAppVersion,
    DateTime? now,
  }) async {
    final root = docs ?? Storage.docsDir;
    final archive = Archive();
    final collected = <String, List<int>>{};

    for (final sub in dataDirs) {
      final dir = Directory('${root.path}${Platform.pathSeparator}$sub');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final rel = _relativePath(root.path, entity.path);
        if (rel == null) continue;
        try {
          collected[rel] = await entity.readAsBytes();
        } catch (_) {
          // 单个文件读失败不影响其它数据
        }
      }
    }

    final manifest = BackupManifest(
      appVersion: appVersion,
      createdAt: (now ?? DateTime.now()).toUtc(),
      fileCount: collected.length,
      prefCount: (prefs ?? const <String, Object?>{}).length,
      prefs: prefs ?? const <String, Object?>{},
    );
    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    archive.addFile(
      ArchiveFile(manifestName, manifestBytes.length, manifestBytes),
    );
    for (final entry in collected.entries) {
      final bytes = entry.value;
      archive.addFile(
        ArchiveFile('$filesPrefix/${entry.key}', bytes.length, bytes),
      );
    }
    final encoded = ZipEncoder().encode(archive) ?? const <int>[];
    return Uint8List.fromList(encoded);
  }

  /// 解析并校验备份包（不写盘）。
  static BackupArchive parseBackup(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const BackupException('备份文件是空的');
    }
    final Archive archive;
    try {
      final decoded = ZipDecoder().decodeBytes(bytes);
      archive = decoded;
    } catch (_) {
      throw const BackupException('这不是有效的 zip 文件，或者文件已损坏');
    }

    // v0.41.0：先按「未解压大小」卡上限，避免恶意包在遍历时把内存吃爆
    final entries = archive.files.where((f) => f.isFile).toList();
    if (entries.length > maxEntries) {
      throw BackupException(
        '这个备份包文件太多（${entries.length} 个），为安全起见已拒绝恢复',
      );
    }
    var totalSize = 0;
    for (final entry in entries) {
      if (entry.size > maxSingleFileBytes) {
        throw BackupException(
          '备份包里有一个文件解压后超过 200MB（${entry.name}），已拒绝恢复',
        );
      }
      totalSize += entry.size;
      if (totalSize > maxUncompressedBytes) {
        throw const BackupException(
          '这个备份包解压后超过 1GB，为安全起见已拒绝恢复',
        );
      }
    }

    Map<String, dynamic>? manifestJson;
    final files = <String, List<int>>{};
    for (final entry in entries) {
      final name = entry.name;
      if (name == manifestName) {
        try {
          final raw = utf8.decode(entry.content as List<int>);
          manifestJson = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          throw const BackupException('备份清单损坏，无法读取');
        }
        continue;
      }
      if (name == '$filesPrefix/' || name == filesPrefix) continue;
      if (name.startsWith('$filesPrefix/')) {
        final rel = name.substring(filesPrefix.length + 1);
        final error = _validateRelativePath(rel);
        if (error != null) {
          throw BackupException('备份包里的路径不安全：$rel（$error）');
        }
        files[rel] = entry.content as List<int>;
      }
    }

    if (manifestJson == null) {
      throw const BackupException('这不是 LiteTavern 的备份文件（缺少清单）');
    }
    if (manifestJson['format'] != format) {
      throw const BackupException('这不是 LiteTavern 的备份文件');
    }
    final version = (manifestJson['formatVersion'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      throw BackupException(
        '这份备份来自更新的版本（格式 v$version），当前 App 只能读到 v$formatVersion',
      );
    }

    final prefs = <String, Object?>{};
    final rawPrefs = manifestJson['prefs'];
    if (rawPrefs is Map) {
      for (final entry in rawPrefs.entries) {
        final value = entry.value;
        if (value is bool ||
            value is int ||
            value is double ||
            value is String ||
            value is List) {
          prefs[entry.key.toString()] = value;
        }
      }
    }

    return BackupArchive(
      manifest: BackupManifest.fromJson(manifestJson),
      files: files,
      prefs: prefs,
    );
  }

  /// 把备份写回文档目录与设置。返回写入的文件数。
  ///
  /// [options] 用来只恢复一部分（v0.38.0）：没勾选的数据目录会跳过，
  /// 设置项只在勾了 [BackupRestoreOptions.settings] 时才写回。
  static Future<int> restoreBackup(
    BackupArchive archive, {
    Directory? docs,
    bool replacePrefs = true,
    BackupRestoreOptions options = BackupRestoreOptions.all,
  }) async {
    if (!options.any) {
      throw const BackupException('没有选择要恢复的内容');
    }
    final root = docs ?? Storage.docsDir;
    var written = 0;
    for (final entry in archive.files.entries) {
      final error = _validateRelativePath(entry.key);
      if (error != null) {
        throw BackupException('备份包里的路径不安全：${entry.key}（$error）');
      }
      if (!options.allowsDir(entry.key.split('/').first)) continue;
      final target = File(
        '${root.path}${Platform.pathSeparator}'
        '${entry.key.replaceAll('/', Platform.pathSeparator)}',
      );
      try {
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.value, flush: true);
        written++;
      } catch (e) {
        throw BackupException('写入 ${entry.key} 失败：$e');
      }
    }
    if (replacePrefs && options.settings && archive.prefs.isNotEmpty) {
      await AppSettings.importPrefs(archive.prefs);
    }
    return written;
  }

  /// 生成一个临时 .zip 文件（调用方负责分享/清理）。
  static Future<File> writeTempZip(
    Uint8List bytes, {
    Directory? directory,
    DateTime? now,
  }) async {
    final dir = directory ?? await _tempDir();
    String p2(int n) => n.toString().padLeft(2, '0');
    final at = now ?? DateTime.now();
    final stamp = '${at.year}${p2(at.month)}${p2(at.day)}_'
        '${p2(at.hour)}${p2(at.minute)}${p2(at.second)}';
    final file = File('${dir.path}${Platform.pathSeparator}LiteTavern_backup_$stamp.zip');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<Directory> _tempDir() async =>
      Directory.systemTemp.createTemp('litetavern_backup_');

  /// 校验备份内的相对路径：必须落在四个数据目录里，且不含 `..` / 绝对路径。
  static String? _validateRelativePath(String rel) {
    if (rel.isEmpty) return '路径为空';
    if (rel.startsWith('/') || rel.startsWith('\\')) return '不允许绝对路径';
    if (RegExp(r'^[a-zA-Z]:').hasMatch(rel)) return '不允许盘符路径';
    final parts = rel.split('/');
    if (parts.any((p) => p.isEmpty || p == '.' || p == '..')) {
      return '路径里不能有 . 或 ..';
    }
    if (!dataDirs.contains(parts.first)) return '不在数据目录内';
    if (parts.length < 2) return '缺少文件名';
    return null;
  }

  static String? _relativePath(String rootPath, String filePath) {
    final rootPrefix =
        rootPath.endsWith(Platform.pathSeparator) ? rootPath : '$rootPath${Platform.pathSeparator}';
    if (!filePath.startsWith(rootPrefix)) return null;
    return filePath.substring(rootPrefix.length).replaceAll(Platform.pathSeparator, '/');
  }
}
