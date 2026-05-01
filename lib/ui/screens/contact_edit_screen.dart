import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/contact.dart';
import '../../services/chat_storage_service.dart';
import '../../services/image_service.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/desktop_image_picker.dart';

/// Локальное редактирование контакта: имя, фото, баннер, цвет и эмодзи аватара.
/// Не отправляется в сеть — только у вас в адресной книге.
class ContactEditScreen extends StatefulWidget {
  final Contact contact;

  const ContactEditScreen({super.key, required this.contact});

  @override
  State<ContactEditScreen> createState() => _ContactEditScreenState();
}

class _ContactEditScreenState extends State<ContactEditScreen> {
  late final TextEditingController _nickCtrl;
  late int _color;
  late String _emoji;
  String? _avatarPath;
  String? _bannerPath;
  bool _showEmojiPicker = false;
  bool _saving = false;
  final _picker = ImagePicker();

  Contact get _c => widget.contact;

  @override
  void initState() {
    super.initState();
    _nickCtrl = TextEditingController(text: _c.nickname);
    _color = _c.avatarColor;
    _emoji = _c.avatarEmoji;
    _avatarPath = _c.avatarImagePath;
    _bannerPath = _c.bannerImagePath;
  }

  @override
  void dispose() {
    _nickCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final raw = await pickImagePathDesktopAware(imagePicker: _picker);
    if (raw == null || !mounted) return;
    final path = await ImageService.instance.compressAndSave(
      raw,
      isAvatar: true,
    );
    setState(() => _avatarPath = path);
  }

  Future<void> _pickBanner() async {
    final raw = await pickImagePathDesktopAware(imagePicker: _picker);
    if (raw == null || !mounted) return;
    final path = await ImageService.instance.compressAndSave(
      raw,
      maxSize: 1200,
    );
    setState(() => _bannerPath = path);
  }

  Future<void> _save() async {
    final nick = _nickCtrl.text.trim();
    if (nick.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите имя')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ChatStorageService.instance.saveContact(
        _c.copyWith(
          nickname: nick,
          avatarColor: _color,
          avatarEmoji: _emoji,
          avatarImagePath: _avatarPath,
          setAvatarImagePath: true,
          bannerImagePath: _bannerPath,
          setBannerImagePath: true,
        ),
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bannerFile = _bannerPath != null && _bannerPath!.isNotEmpty
        ? File(ImageService.instance.resolveStoredPath(_bannerPath!) ??
            _bannerPath!)
        : null;
    final bannerResolved = bannerFile != null && bannerFile.existsSync();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Контакт'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Сохранить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Только на вашем устройстве. Собеседник не узнает об этих изменениях.',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _pickBanner,
            child: Container(
              width: double.infinity,
              height: 120,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: cs.surfaceContainerHigh,
                image: bannerResolved
                    ? DecorationImage(
                        image: FileImage(bannerFile),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: bannerResolved
                  ? Align(
                      alignment: Alignment.topRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Убрать баннер',
                            onPressed: () => setState(() => _bannerPath = null),
                            icon: const Icon(Icons.close, color: Colors.white),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              color: cs.onSurfaceVariant, size: 32),
                          const SizedBox(height: 4),
                          Text(
                            'Обложка (баннер)',
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GestureDetector(
                      onTap: () => setState(
                          () => _showEmojiPicker = !_showEmojiPicker),
                      child: AvatarWidget(
                        initials: _nickCtrl.text.isNotEmpty
                            ? _nickCtrl.text[0].toUpperCase()
                            : '?',
                        color: _color,
                        emoji: _emoji,
                        imagePath: _avatarPath,
                        size: 96,
                      ),
                    ),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Material(
                        color: const Color(0xFF1DB954),
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Фото',
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          icon: const Icon(Icons.photo_camera,
                              size: 18, color: Colors.white),
                          onPressed: _pickAvatar,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_avatarPath != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _avatarPath = null),
                    child: const Text('Убрать фото аватара'),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Нажмите на аватар — эмодзи; камера — фото',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_showEmojiPicker) ...[
            const SizedBox(height: 8),
            AvatarEmojiPicker(
              selected: _emoji.isNotEmpty ? _emoji : '🙂',
              onSelected: (e) {
                setState(() {
                  _emoji = e;
                  _showEmojiPicker = false;
                });
              },
            ),
          ],
          if (_avatarPath == null) ...[
            const SizedBox(height: 16),
            const Text('Цвет фона',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            SizedBox(
              width: MediaQuery.sizeOf(context).width - 32,
              child: AvatarColorPicker(
                selected: _color,
                onSelected: (c) => setState(() => _color = c),
              ),
            ),
            const SizedBox(height: 20),
          ],
          TextField(
            controller: _nickCtrl,
            decoration: const InputDecoration(
              labelText: 'Имя в контактах',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          if (_c.username.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Юзернейм в сети: #${_c.username}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
