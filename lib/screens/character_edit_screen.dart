import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// 角色编辑页：编辑名字/简介/性格/场景/开场白，展示 alternate_greetings 与内嵌世界书。
class CharacterEditScreen extends StatefulWidget {
  final String charId;

  const CharacterEditScreen({super.key, required this.charId});

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  CharacterCard? _card;
  bool _loading = true;
  bool _saving = false;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _personalityCtrl;
  late final TextEditingController _scenarioCtrl;
  late final TextEditingController _firstMesCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _personalityCtrl = TextEditingController();
    _scenarioCtrl = TextEditingController();
    _firstMesCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _personalityCtrl.dispose();
    _scenarioCtrl.dispose();
    _firstMesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final card = await Storage.loadCharacter(widget.charId);
    if (!mounted) return;
    if (card == null) {
      Navigator.of(context).pop();
      return;
    }
    _nameCtrl.text = card.name;
    _descCtrl.text = card.description;
    _personalityCtrl.text = card.personality;
    _scenarioCtrl.text = card.scenario;
    _firstMesCtrl.text = card.firstMes;
    setState(() {
      _card = card;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final card = _card;
    if (card == null || _saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名字不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    final updated = card.copyWith(
      name: name,
      description: _descCtrl.text,
      personality: _personalityCtrl.text,
      scenario: _scenarioCtrl.text,
      firstMes: _firstMesCtrl.text,
    );
    await Storage.saveCharacter(updated);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = _card;

    if (_loading || card == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑角色')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final bookCount = card.characterBook?.entries.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑角色'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  CharacterAvatar(id: card.id, name: _nameCtrl.text, size: 88),
                  const SizedBox(height: 8),
                  Text(
                    '头像来自角色卡原图（无原图时为名字首字）',
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _label('名字'),
            TextField(controller: _nameCtrl, decoration: _hint('角色名字')),
            const SizedBox(height: 16),
            _label('简介'),
            TextField(
              controller: _descCtrl,
              decoration: _hint('角色描述 / 背景设定'),
              maxLines: 5,
              minLines: 2,
            ),
            const SizedBox(height: 16),
            _label('性格'),
            TextField(
              controller: _personalityCtrl,
              decoration: _hint('性格特点'),
              maxLines: 4,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            _label('场景'),
            TextField(
              controller: _scenarioCtrl,
              decoration: _hint('当前场景 / 故事背景'),
              maxLines: 4,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            _label('开场白'),
            TextField(
              controller: _firstMesCtrl,
              decoration: _hint('角色的第一条消息'),
              maxLines: 6,
              minLines: 2,
            ),
            if (card.alternateGreetings.isNotEmpty) ...[
              const SizedBox(height: 20),
              _label('备选开场白（${card.alternateGreetings.length} 条，聊天中可轮换）'),
              const SizedBox(height: 8),
              for (var i = 0; i < card.alternateGreetings.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          card.alternateGreetings[i],
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (bookCount > 0) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text('内嵌世界书：$bookCount 条'),
                  subtitle: const Text('随角色卡自动参与关键词匹配（只读）'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  InputDecoration _hint(String hint) =>
      InputDecoration(hintText: hint, isDense: true);
}
