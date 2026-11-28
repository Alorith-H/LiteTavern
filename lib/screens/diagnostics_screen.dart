import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../widgets/common.dart';

/// 诊断日志页（v0.41.0 商用加固）。
///
/// 崩溃或报错后，用户可以在这里看到最近的记录并复制出来，避免「出问题了但没有任何线索」。
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<String>? _lines;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = await AppLog.recent(max: 150);
    if (!mounted) return;
    setState(() => _lines = lines);
  }

  Future<void> _clear() async {
    await AppLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = _lines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        actions: [
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: lines == null
          ? const Center(child: CircularProgressIndicator())
          : lines.isEmpty
              ? Center(
                  child: Text(
                    '还没有记录。',
                    style: TextStyle(
                      fontSize: AppType.body,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Text(
                      '最近 ${lines.length} 条（新的在上）。出问题时可以把这段内容发给我。',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      lines.join('\n\n'),
                      style: TextStyle(
                        fontSize: AppType.meta,
                        height: 1.45,
                        fontFamily: 'monospace',
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
    );
  }
}
