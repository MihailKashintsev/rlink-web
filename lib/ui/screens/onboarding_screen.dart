import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user_profile.dart';
import '../../services/crypto_service.dart';
import '../../services/image_service.dart';
import '../../services/profile_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_list_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();
  int _selectedColor = UserProfile.avatarColors[0];
  String _selectedEmoji = UserProfile.avatarEmojis[0];
  String? _selectedImagePath;
  bool _loading = false;
  bool _showEmojiPicker = false;

  final _picker = ImagePicker();

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final path = await ImageService.instance.compressAndSave(
      picked.path,
      isAvatar: true,
    );
    setState(() => _selectedImagePath = path);
  }

  String get _initials {
    final text = _controller.text.trim();
    if (text.isEmpty) return '?';
    final parts = text.split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return text[0].toUpperCase();
  }

  static const _maxNickLength = 20;

  Future<void> _create() async {
    final nick = _controller.text.trim();
    if (nick.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Имя должно быть не короче 2 символов')),
      );
      return;
    }
    if (nick.length > _maxNickLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Имя не должно превышать $_maxNickLength символов')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      // Создаём профиль через ProfileService
      await ProfileService.instance.createProfile(
        publicKeyHex: CryptoService.instance.publicKeyHex,
        nickname: nick,
      );
      // Обновляем эмодзи, цвет и фото
      await ProfileService.instance.updateProfile(
        nickname: nick,
        avatarColor: _selectedColor,
        avatarEmoji: _selectedEmoji,
        avatarImagePath: _selectedImagePath,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка регистрации: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),

              // Логотип
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFF1DB954),
                  borderRadius: BorderRadius.circular(18),
                ),
                child:
                    const Icon(Icons.bluetooth, color: Colors.white, size: 40),
              ),
              const SizedBox(height: 20),
              const Text('Rlink',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'Мессенджер без интернета через Bluetooth',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 36),

              // Аватар — тап для смены эмодзи, кнопка фото слева
              Stack(
                children: [
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showEmojiPicker = !_showEmojiPicker),
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (_, __) => AvatarWidget(
                        initials: _initials,
                        color: _selectedColor,
                        emoji: _selectedEmoji,
                        imagePath: _selectedImagePath,
                        size: 84,
                      ),
                    ),
                  ),
                  // Кнопка смены эмодзи
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
                          border: Border.all(
                              color: const Color(0xFF0A0A0A), width: 2),
                        ),
                        child: const Icon(Icons.edit,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                  // Кнопка выбора фото из галереи
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade800,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: const Color(0xFF0A0A0A), width: 2),
                        ),
                        child: const Icon(Icons.photo_camera,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Нажми на аватар чтобы выбрать эмодзи',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 16),

              // Выбор эмодзи (раскрывается)
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _showEmojiPicker
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
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
                // Цвет фона
                const SizedBox(height: 16),
                AvatarColorPicker(
                  selected: _selectedColor,
                  onSelected: (c) => setState(() => _selectedColor = c),
                ),
                const SizedBox(height: 24),

                // Поле имени
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textAlign: TextAlign.center,
                  maxLength: _maxNickLength,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: 'Твоё имя',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF1A1A1A),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    counterStyle:
                        TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                  onSubmitted: (_) => _create(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),

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
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Начать',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600)),
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
