import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../../main.dart' show broadcastMyAvatar;
import '../widgets/avatar_widget.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _tagColors = [
    Color(0xFF1DB954),
    Color(0xFF2196F3),
    Color(0xFFFF7043),
    Color(0xFFAB47BC),
    Color(0xFFFFCA28),
  ];
  late TextEditingController _controller;
  late TextEditingController _tagController;
  late int _selectedColor;
  late String _selectedEmoji;
  String? _selectedImagePath;
  String? _bannerImagePath;
  late List<String> _tags;
  bool _editing = false;
  bool _saving = false;
  bool _showEmojiPicker = false;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final p = ProfileService.instance.profile!;
    _controller = TextEditingController(text: p.nickname);
    _tagController = TextEditingController();
    _selectedColor = p.avatarColor;
    _selectedEmoji = p.avatarEmoji;
    _selectedImagePath = p.avatarImagePath;
    _bannerImagePath = p.bannerImagePath;
    _tags = List<String>.from(p.tags);
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final path = await ImageService.instance.compressAndSave(
      picked.path,
      isAvatar: true,
    );
    setState(() => _selectedImagePath = path);
  }

  Future<void> _pickBanner() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final path = await ImageService.instance.compressAndSave(
      picked.path,
      maxSize: 1200,
    );
    setState(() => _bannerImagePath = path);
  }

  void _addTag() {
    final tag = _tagController.text.trim();
    if (tag.isEmpty || _tags.length >= 5 || _tags.contains(tag)) return;
    setState(() {
      _tags.add(tag);
      _tagController.clear();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final updated = await ProfileService.instance.updateProfile(
        nickname: _controller.text.trim(),
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
        avatarImagePath: _selectedImagePath,
        tags: _tags,
        bannerImagePath: _bannerImagePath,
      );
      setState(() {
        _editing = false;
        _showEmojiPicker = false;
      });
      // Broadcast updated profile + avatar to all peers
      final x25519 = CryptoService.instance.x25519PublicKeyBase64;
      GossipRouter.instance.broadcastProfile(
        id: updated.publicKeyHex,
        nick: updated.nickname,
        color: updated.avatarColor,
        emoji: updated.avatarEmoji,
        x25519Key: x25519,
      );
      if (updated.avatarImagePath != null) {
        broadcastMyAvatar();
      }
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
                  ? const SizedBox(
                      width: 20,
                      height: 20,
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
          // Баннер
          GestureDetector(
            onTap: _editing ? _pickBanner : null,
            child: Container(
              width: double.infinity,
              height: 120,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                image: _bannerImagePath != null && File(_bannerImagePath!).existsSync()
                    ? DecorationImage(
                        image: FileImage(File(_bannerImagePath!)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _bannerImagePath == null || !File(_bannerImagePath!).existsSync()
                  ? Center(
                      child: _editing
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_photo_alternate_outlined,
                                    color: Theme.of(context).hintColor, size: 32),
                                const SizedBox(height: 4),
                                Text('Добавить баннер',
                                    style: TextStyle(
                                        color: Theme.of(context).hintColor, fontSize: 12)),
                              ],
                            )
                          : Icon(Icons.panorama_outlined,
                              color: Theme.of(context).hintColor, size: 40),
                    )
                  : _editing
                      ? Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: CircleAvatar(
                              radius: 14,
                              backgroundColor: Colors.black54,
                              child: Icon(Icons.edit, size: 14, color: Colors.white),
                            ),
                          ),
                        )
                      : null,
            ),
          ),
          const SizedBox(height: 16),

          // Аватар
          Center(
            child: Stack(children: [
              GestureDetector(
                onTap: _editing
                    ? () => setState(() => _showEmojiPicker = !_showEmojiPicker)
                    : null,
                child: AvatarWidget(
                  initials: (_editing && _controller.text.isNotEmpty)
                      ? _controller.text[0].toUpperCase()
                      : profile.initials,
                  color: _editing ? _selectedColor : profile.avatarColor,
                  emoji: _editing ? _selectedEmoji : profile.avatarEmoji,
                  imagePath:
                      _editing ? _selectedImagePath : profile.avatarImagePath,
                  size: 88,
                ),
              ),
              if (_editing) ...[
                // Кнопка смены эмодзи
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _showEmojiPicker = !_showEmojiPicker),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1DB954),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor, width: 2),
                      ),
                      child:
                          const Icon(Icons.edit, size: 14, color: Colors.white),
                    ),
                  ),
                ),
                // Кнопка выбора фото
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor, width: 2),
                      ),
                      child: const Icon(Icons.photo_camera,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ]),
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
                        color: Theme.of(context).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: AvatarEmojiPicker(
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
                    counterStyle:
                        TextStyle(color: Theme.of(context).hintColor, fontSize: 11),
                  ),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                )
              : _InfoTile(label: 'Имя', value: profile.nickname),

          const SizedBox(height: 12),

          // Краткий код
          _InfoTile(
            label: 'Краткий код',
            value: '#${profile.shortId}',
            monospace: true,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: profile.shortId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Краткий код скопирован!')),
              );
            },
          ),
          const SizedBox(height: 12),

          // Теги
          if (_editing) ...[
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  decoration: InputDecoration(
                    labelText: 'Добавить тег (макс. 5)',
                    hintText: 'Например: музыка',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: _addTag,
                    ),
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
            ]),
            const SizedBox(height: 8),
          ],
          if (_tags.isNotEmpty || !_editing)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ..._tags.asMap().entries.map((entry) {
                  final i = entry.key;
                  final tag = entry.value;
                  final color = _tagColors[i % _tagColors.length];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('#$tag',
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            )),
                        if (_editing) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => setState(() => _tags.remove(tag)),
                            child: Icon(Icons.close, size: 14, color: color),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
                if (_tags.isEmpty && !_editing)
                  Text('Нет тегов',
                      style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
              ],
            ),
          const SizedBox(height: 12),

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
  const _InfoTile(
      {required this.label,
      required this.value,
      this.monospace = false,
      this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 14, fontFamily: monospace ? 'monospace' : null),
                overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (onCopy != null)
          IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: onCopy),
      ]),
    );
  }
}
