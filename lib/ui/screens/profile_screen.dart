import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../../models/user_profile.dart';
import '../../services/gigachat_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../../main.dart'
    show broadcastMyAvatar, broadcastMyBanner, broadcastMyProfileMusic, sendProfileToAllContacts;
import '../widgets/avatar_widget.dart';
import '../widgets/desktop_image_picker.dart';

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
  late TextEditingController _usernameController;
  late TextEditingController _tagController;
  late int _selectedColor;
  late String _selectedEmoji;
  late String _statusEmoji;
  String? _selectedImagePath;
  String? _bannerImagePath;
  String? _profileMusicPath;
  late List<String> _tags;
  bool _editing = false;
  bool _saving = false;
  bool _showEmojiPicker = false;
  bool _showStatusEmojiPicker = false;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final p = ProfileService.instance.profile!;
    _controller = TextEditingController(text: p.nickname);
    _usernameController = TextEditingController(text: p.username);
    _tagController = TextEditingController();
    _selectedColor = p.avatarColor;
    _selectedEmoji = p.avatarEmoji;
    _statusEmoji = p.statusEmoji;
    _selectedImagePath = p.avatarImagePath;
    _bannerImagePath = p.bannerImagePath;
    _profileMusicPath = p.profileMusicPath;
    _tags = List<String>.from(p.tags);
  }

  Future<void> _pickImage() async {
    final raw = await pickImagePathDesktopAware(imagePicker: _picker);
    if (raw == null) return;
    if (kIsWeb) {
      setState(() => _selectedImagePath = raw);
      return;
    }
    final path = await ImageService.instance.compressAndSave(
      raw,
      isAvatar: true,
    );
    setState(() => _selectedImagePath = path);
  }

  Future<void> _pickBanner() async {
    final raw = await pickImagePathDesktopAware(imagePicker: _picker);
    if (raw == null) return;
    if (kIsWeb) {
      setState(() => _bannerImagePath = raw);
      return;
    }
    final path = await ImageService.instance.compressAndSave(
      raw,
      maxSize: 1200,
    );
    setState(() => _bannerImagePath = path);
  }

  Future<void> _pickProfileMusic() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );
    if (r == null || r.files.isEmpty) return;
    final src = r.files.single.path;
    if (src == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final sub = Directory(p.join(dir.path, 'profile_audio'))..createSync(recursive: true);
    final ext = p.extension(src).isEmpty ? '.m4a' : p.extension(src);
    final dest = p.join(sub.path, 'me_profile$ext');
    await File(src).copy(dest);
    setState(() => _profileMusicPath = dest);
  }

  void _clearProfileMusic() => setState(() => _profileMusicPath = null);

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
    _usernameController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final prevProfile = ProfileService.instance.profile!;
      final prevAvatar = prevProfile.avatarImagePath;
      final prevBanner = prevProfile.bannerImagePath;
      final prevMusic = prevProfile.profileMusicPath;

      final rawUsername = _usernameController.text.trim().toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_.]'), '');
      final updated = await ProfileService.instance.updateProfile(
        nickname: _controller.text.trim(),
        username: rawUsername,
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
        avatarImagePath: _selectedImagePath,
        tags: _tags,
        bannerImagePath: _bannerImagePath,
        profileMusicPath: _profileMusicPath,
        statusEmoji: _statusEmoji,
      );
      setState(() {
        _editing = false;
        _showEmojiPicker = false;
        _showStatusEmojiPicker = false;
      });
      // Send updated profile directly to all contacts via relay
      sendProfileToAllContacts();
      // Also broadcast via gossip for BLE peers
      final x25519 = CryptoService.instance.x25519PublicKeyBase64;
      GossipRouter.instance.broadcastProfile(
        id: updated.publicKeyHex,
        nick: updated.nickname,
        username: updated.username,
        color: updated.avatarColor,
        emoji: updated.avatarEmoji,
        x25519Key: x25519,
        tags: updated.tags,
        statusEmoji: updated.statusEmoji,
      );
      // Если аватар/баннер реально изменились — перешлём изображения контактам,
      // чтобы у них обновилась картинка (а не только метаданные профиля).
      if (!kIsWeb &&
          updated.avatarImagePath != null &&
          updated.avatarImagePath != prevAvatar) {
        unawaited(broadcastMyAvatar());
      }
      if (!kIsWeb &&
          updated.bannerImagePath != null &&
          updated.bannerImagePath != prevBanner) {
        unawaited(broadcastMyBanner());
      }
      if (updated.profileMusicPath != prevMusic) {
        unawaited(broadcastMyProfileMusic());
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
                image: _bannerImagePath != null &&
                        (kIsWeb || File(_bannerImagePath!).existsSync())
                    ? DecorationImage(
                        image: kIsWeb
                            ? NetworkImage(_bannerImagePath!)
                            : FileImage(File(_bannerImagePath!)) as ImageProvider,
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _bannerImagePath == null ||
                      (!kIsWeb && !File(_bannerImagePath!).existsSync())
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
                      ? const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(8),
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
                    ? () => setState(() {
                          _showEmojiPicker = !_showEmojiPicker;
                          _showStatusEmojiPicker = false;
                        })
                    : null,
                child: Hero(
                  tag: 'avatar_my_profile',
                  child: Material(
                    color: Colors.transparent,
                    child: AvatarWidget(
                      initials: (_editing && _controller.text.isNotEmpty)
                          ? _controller.text[0].toUpperCase()
                          : profile.initials,
                      color: _editing ? _selectedColor : profile.avatarColor,
                      emoji: _editing ? _selectedEmoji : profile.avatarEmoji,
                      imagePath: _editing
                          ? _selectedImagePath
                          : profile.avatarImagePath,
                      size: 88,
                    ),
                  ),
                ),
              ),
              if (_editing) ...[
                // Кнопка смены эмодзи
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _showEmojiPicker = !_showEmojiPicker;
                      _showStatusEmojiPicker = false;
                    }),
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
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _showStatusEmojiPicker
                  ? Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: AvatarEmojiPicker(
                        selected: _statusEmoji.isNotEmpty
                            ? _statusEmoji
                            : UserProfile.avatarEmojis.first,
                        onSelected: (e) => setState(() {
                          _statusEmoji = UserProfile.normalizeStatusEmoji(e);
                          _showStatusEmojiPicker = false;
                        }),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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

          // Эмодзи-статус (рядом с именем в списках)
          _editing
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Эмодзи-статус',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            onTap: () => setState(() {
                              _showStatusEmojiPicker = !_showStatusEmojiPicker;
                              _showEmojiPicker = false;
                            }),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Text(
                                _statusEmoji.isEmpty ? '—' : _statusEmoji,
                                style: const TextStyle(fontSize: 22),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_statusEmoji.isNotEmpty)
                          TextButton(
                            onPressed: () =>
                                setState(() => _statusEmoji = ''),
                            child: const Text('Убрать'),
                          ),
                      ],
                    ),
                  ],
                )
              : _InfoTile(
                  label: 'Эмодзи-статус',
                  value: profile.statusEmoji.isEmpty
                      ? 'Не задан'
                      : profile.statusEmoji,
                ),

          const SizedBox(height: 12),

          // Юзернейм
          _editing
              ? TextField(
                  controller: _usernameController,
                  maxLength: 24,
                  decoration: InputDecoration(
                    labelText: 'Юзернейм',
                    hintText: 'Например: ivan_99',
                    prefixText: '#',
                    border: const OutlineInputBorder(),
                    counterStyle:
                        TextStyle(color: Theme.of(context).hintColor, fontSize: 11),
                    helperText: 'Латиница, цифры, _ и . — для быстрого поиска',
                    helperStyle:
                        TextStyle(color: Theme.of(context).hintColor, fontSize: 11),
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_.]')),
                  ],
                )
              : _InfoTile(
                  label: 'Юзернейм',
                  value: profile.username.isNotEmpty
                      ? '#${profile.username}'
                      : 'Не задан',
                  monospace: profile.username.isNotEmpty,
                  onCopy: profile.username.isNotEmpty
                      ? () {
                          Clipboard.setData(ClipboardData(text: profile.username));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Юзернейм скопирован!')),
                          );
                        }
                      : null,
                ),
          const SizedBox(height: 12),

          // Музыка в профиле (контакты получат файл при связи)
          Builder(builder: (context) {
            final rp = _profileMusicPath == null
                ? null
                : (ImageService.instance.resolveStoredPath(_profileMusicPath) ??
                    _profileMusicPath);
            final hasMusic = rp != null && File(rp).existsSync();
            final sub = hasMusic
                ? p.basename(rp)
                : (_editing
                    ? 'Выберите аудиофайл — контакты смогут загрузить и послушать, когда вы в сети'
                    : 'Не выбрано');
            return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('Музыка в профиле'),
            subtitle: Text(
              sub,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            trailing: _editing
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_profileMusicPath != null)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Убрать',
                          onPressed: _clearProfileMusic,
                        ),
                      IconButton(
                        icon: const Icon(Icons.audio_file_outlined),
                        tooltip: 'Выбрать файл',
                        onPressed: _pickProfileMusic,
                      ),
                    ],
                  )
                : null,
            );
          }),
          const SizedBox(height: 8),

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

          const _GigaChatProfileCard(),
          const SizedBox(height: 12),

          _InfoTile(
            label: 'Полный ID (для поиска через &)',
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

class _GigaChatProfileCard extends StatefulWidget {
  const _GigaChatProfileCard();

  @override
  State<_GigaChatProfileCard> createState() => _GigaChatProfileCardState();
}

class _GigaChatProfileCardState extends State<_GigaChatProfileCard> {
  late final TextEditingController _keyCtrl;
  bool _obscure = true;
  bool _loading = true;
  bool _saving = false;
  bool _insecureTlsWorkaround = false;
  bool _savingTlsOption = false;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController();
    unawaited(_load());
  }

  Future<void> _load() async {
    final k = await GigachatService.instance.readAuthorizationKey();
    final insecure =
        await GigachatService.instance.readInsecureTlsWorkaroundEnabled();
    if (!mounted) return;
    setState(() {
      _keyCtrl.text = k ?? '';
      _insecureTlsWorkaround = insecure;
      _loading = false;
    });
  }

  Future<void> _setInsecureTlsWorkaround(bool value) async {
    setState(() => _savingTlsOption = true);
    try {
      await GigachatService.instance.setInsecureTlsWorkaroundEnabled(value);
      if (!mounted) return;
      setState(() => _insecureTlsWorkaround = value);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value
                  ? 'Включён обход проверки сертификата для узлов GigaChat'
                  : 'Проверка сертификата снова обычная',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingTlsOption = false);
    }
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await GigachatService.instance
          .saveAuthorizationKey(_keyCtrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ключ GigaChat сохранён')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _saving = true);
    try {
      _keyCtrl.clear();
      await GigachatService.instance.saveAuthorizationKey(null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ключ удалён')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openDoc() async {
    final u = Uri.parse(
        'https://developers.sber.ru/docs/ru/gigachat/quickstart/legal-using-api');
    if (await canLaunchUrl(u)) {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.smart_toy_outlined),
        title: const Text('ИИ-чат (GigaChat)'),
        subtitle: const Text(
          'Ключ для бота в списке чатов',
          style: TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscure,
                  maxLines: 1,
                  decoration: InputDecoration(
                    labelText: 'Authorization Key',
                    hintText: 'Ключ из личного кабинета Сбера',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Сохранить'),
                    ),
                    OutlinedButton(
                      onPressed: _saving ? null : _clear,
                      child: const Text('Удалить ключ'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Обход проверки сертификата (GigaChat)'),
                  subtitle: Text(
                    'Только хосты *.devices.sberbank.ru. Включайте, если из‑за VPN или '
                    'корпоративной сети видите ошибку сертификата. Снижает защиту от перехвата трафика.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: _insecureTlsWorkaround,
                  onChanged: _savingTlsOption
                      ? null
                      : (v) => unawaited(_setInsecureTlsWorkaround(v)),
                ),
                const Divider(height: 28),
                Text(
                  'Как получить ключ',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '1. Откройте портал Сбер для разработчиков (developers.sber.ru) и войдите в аккаунт.\n'
                  '2. Создайте проект с подключением GigaChat API (раздел продуктов и API).\n'
                  '3. В настройках проекта получите Client ID и Client Secret или сразу скопируйте '
                  'готовое значение «Ключ авторизации» (Authorization Key) — длинная строка Base64.\n'
                  '4. Вставьте ключ в поле выше. Если в кабинете ключ без слова Basic — приложение '
                  'добавит префикс само.\n'
                  '5. Для физических лиц используется область доступа GIGACHAT_API_PERS (уже выбрана в приложении).\n'
                  '6. Тексты из чата с ботом отправляются на серверы Сбера; не передавайте туда пароли и персональные данные третьих лиц.\n\n'
                  'Если запросы не проходят, проверьте интернет и что сертификаты устройства доверяют узлам Сбера.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _openDoc,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Документация: быстрый старт GigaChat'),
                ),
              ],
            ),
          ),
        ],
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
