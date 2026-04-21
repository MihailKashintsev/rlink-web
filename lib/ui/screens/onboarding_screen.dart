import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user_profile.dart';
import '../../services/app_settings.dart';
import '../../services/ble_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../../services/relay_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_list_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nickController     = TextEditingController();
  final _usernameController = TextEditingController();
  final _usernameFocus      = FocusNode();

  int     _selectedColor = UserProfile.avatarColors[0];
  String  _selectedEmoji = UserProfile.avatarEmojis[0];
  String? _selectedImagePath;
  bool    _loading         = false;
  bool    _showEmojiPicker = false;

  final _picker = ImagePicker();

  static const _maxNickLength     = 20;
  static const _maxUsernameLength = 20;

  // ── Validation ────────────────────────────────────────────────

  String get _initials {
    final text = _nickController.text.trim();
    if (text.isEmpty) return '?';
    final parts = text.split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return text[0].toUpperCase();
  }

  /// null = valid, otherwise error message
  String? get _usernameError {
    final u = _usernameController.text.trim();
    if (u.isEmpty) return null;
    if (u.length < 3) return 'Минимум 3 символа';
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(u)) {
      return 'Только буквы, цифры и _';
    }
    return null;
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final path = await ImageService.instance.compressAndSave(
      picked.path,
      isAvatar: true,
    );
    setState(() => _selectedImagePath = path);
  }

  Future<void> _create() async {
    final nick     = _nickController.text.trim();
    var username = _usernameController.text.trim().toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9_.]'), '');

    if (nick.length < 2) {
      _showSnack('Имя должно быть не короче 2 символов');
      return;
    }
    if (nick.length > _maxNickLength) {
      _showSnack('Имя не должно превышать $_maxNickLength символов');
      return;
    }
    if (_usernameError != null) {
      _showSnack(_usernameError!);
      return;
    }
    if (username.length < 3) {
      final k = CryptoService.instance.publicKeyHex;
      username = 'user_${k.length >= 10 ? k.substring(0, 10) : k}';
    }

    setState(() => _loading = true);
    try {
      await ProfileService.instance.createProfile(
        publicKeyHex: CryptoService.instance.publicKeyHex,
        nickname: nick,
      );
      await ProfileService.instance.updateProfile(
        nickname: nick,
        username: username,
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
        avatarImagePath: _selectedImagePath,
      );
      // Restart transports with new identity.
      // BLE was stopped during reset — start() restores it.
      // Relay needs to reconnect so the server registers the new public key.
      // For first-launch (BLE already running) start() is a no-op;
      // relay reconnect is harmless if already connected.
      unawaited(_restartTransports(ProfileService.instance.profile!));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } catch (e) {
      if (mounted) _showSnack('Ошибка регистрации: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : null,
    ));
  }

  /// Restart BLE + relay after profile creation so both transports use the
  /// new identity immediately — without requiring an app restart.
  Future<void> _restartTransports(UserProfile profile) async {
    // BLE: start() is safe to call even if already running.
    // After a full reset, BLE was stopped — this restores it.
    if (AppSettings.instance.connectionMode != 1) {
      try { await BleService.instance.start(); } catch (e) {
        debugPrint('[Onboarding] BLE start error: $e');
      }
    }
    // Relay: reconnect so the server registers our new public key.
    if (AppSettings.instance.connectionMode >= 1) {
      try { RelayService.instance.reconnect(); } catch (e) {
        debugPrint('[Onboarding] Relay reconnect error: $e');
      }
    }
    // Broadcast our profile over gossip so any already-connected BLE peers
    // learn our new identity without waiting for the next connection cycle.
    try {
      await GossipRouter.instance.broadcastProfile(
        id: profile.publicKeyHex,
        nick: profile.nickname,
        username: profile.username,
        color: profile.avatarColor,
        emoji: profile.avatarEmoji,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: profile.tags,
      );
    } catch (e) {
      debugPrint('[Onboarding] Profile broadcast error: $e');
    }
  }

  @override
  void dispose() {
    _nickController.dispose();
    _usernameController.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),

              // ── Логотип ──────────────────────────────────────
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFF1DB954),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.bluetooth, color: Colors.white, size: 40),
              ),
              const SizedBox(height: 20),
              Text(
                'Rlink',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Мессенджер без интернета через Bluetooth',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 36),

              // ── Аватар ───────────────────────────────────────
              Stack(
                children: [
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showEmojiPicker = !_showEmojiPicker),
                    child: AnimatedBuilder(
                      animation: _nickController,
                      builder: (_, __) => AvatarWidget(
                        initials: _initials,
                        color: _selectedColor,
                        emoji: _selectedEmoji,
                        imagePath: _selectedImagePath,
                        size: 84,
                      ),
                    ),
                  ),
                  // Редактировать эмодзи
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _showEmojiPicker = !_showEmojiPicker),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1DB954),
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                        child: const Icon(Icons.edit, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                  // Выбрать фото
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                        child: Icon(Icons.photo_camera,
                            size: 14, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Нажми на аватар чтобы выбрать эмодзи',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 16),

              // ── Выбор эмодзи ─────────────────────────────────
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _showEmojiPicker
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
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

              if (!_showEmojiPicker) ...[
                const SizedBox(height: 16),

                // ── Цвет аватара ──────────────────────────────
                AvatarColorPicker(
                  selected: _selectedColor,
                  onSelected: (c) => setState(() => _selectedColor = c),
                ),
                const SizedBox(height: 24),

                // ── Поле имени ────────────────────────────────
                TextField(
                  controller: _nickController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textAlign: TextAlign.center,
                  maxLength: _maxNickLength,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Твоё имя',
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF1A1A1A)
                        : cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    counterStyle:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
                  onSubmitted: (_) => _usernameFocus.requestFocus(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),

                // ── Поле юзернейма ────────────────────────────
                TextField(
                  controller: _usernameController,
                  focusNode: _usernameFocus,
                  textAlign: TextAlign.center,
                  maxLength: _maxUsernameLength,
                  // Only letters, digits, underscore
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                  ],
                  style: TextStyle(
                    fontSize: 16,
                    color: cs.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'Юзернейм (мин. 3 символа; пусто — сгенерируем сами)',
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    prefixIcon: Icon(Icons.alternate_email,
                        size: 20, color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF1A1A1A)
                        : cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    counterStyle:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                    errorText: _usernameController.text.isEmpty
                        ? null
                        : _usernameError,
                    errorStyle: const TextStyle(fontSize: 11),
                  ),
                  onSubmitted: (_) => _create(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),

                // ── Кнопка ───────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _create,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Начать',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
