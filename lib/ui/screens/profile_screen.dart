import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/profile_service.dart';
import '../widgets/avatar_widget.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _controller;
  late int _selectedColor;
  late String _selectedEmoji;
  bool _editing = false;
  bool _saving = false;
  bool _showEmojiPicker = false;

  @override
  void initState() {
    super.initState();
    final p = ProfileService.instance.profile!;
    _controller = TextEditingController(text: p.nickname);
    _selectedColor = p.avatarColor;
    _selectedEmoji = p.avatarEmoji;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ProfileService.instance.updateProfile(
        nickname: _controller.text.trim(),
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
      );
      setState(() { _editing = false; _showEmojiPicker = false; });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.profile!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          if (_editing)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Сохранить'),
            )
          else
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => setState(() => _editing = true),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          // Аватар
          Center(
            child: GestureDetector(
              onTap: _editing
                  ? () => setState(() => _showEmojiPicker = !_showEmojiPicker)
                  : null,
              child: Stack(children: [
                AvatarWidget(
                  initials: (_editing && _controller.text.isNotEmpty)
                      ? _controller.text[0].toUpperCase()
                      : profile.initials,
                  color: _editing ? _selectedColor : profile.avatarColor,
                  emoji: _editing ? _selectedEmoji : profile.avatarEmoji,
                  size: 88,
                ),
                if (_editing)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1DB954),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF0A0A0A), width: 2),
                      ),
                      child: const Icon(Icons.edit, size: 14, color: Colors.white),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 20),

          // Эмодзи пикер
          if (_editing) ...[
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _showEmojiPicker
                  ? Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: EmojiPicker(
                        selected: _selectedEmoji,
                        onSelected: (e) => setState(() {
                          _selectedEmoji = e;
                          _showEmojiPicker = false;
                        }),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            AvatarColorPicker(
              selected: _selectedColor,
              onSelected: (c) => setState(() => _selectedColor = c),
            ),
            const SizedBox(height: 20),
          ],

          // Имя
          _editing
              ? TextField(
                  controller: _controller,
                  maxLength: 20,
                  decoration: InputDecoration(
                    labelText: 'Имя',
                    border: const OutlineInputBorder(),
                    counterStyle: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                )
              : _InfoTile(label: 'Имя', value: profile.nickname),

          const SizedBox(height: 16),

          _InfoTile(
            label: 'Публичный ключ (ID)',
            value: profile.publicKeyHex,
            monospace: true,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: profile.publicKeyHex));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Скопировано!')),
              );
            },
          ),
        ]),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label, value;
  final bool monospace;
  final VoidCallback? onCopy;
  const _InfoTile({required this.label, required this.value, this.monospace = false, this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(fontSize: 14, fontFamily: monospace ? 'monospace' : null),
                overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (onCopy != null)
          IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: onCopy),
      ]),
    );
  }
}
