import 'package:flutter/material.dart';

class AvatarWidget extends StatelessWidget {
  final String initials;
  final int color;
  final String emoji; // если не пустой — показываем эмодзи вместо инициалов
  final double size;
  final bool isOnline;

  const AvatarWidget({
    super.key,
    required this.initials,
    required this.color,
    this.emoji = '',
    this.size = 48,
    this.isOnline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: emoji.isNotEmpty
                ? Text(emoji, style: TextStyle(fontSize: size * 0.46))
                : Text(
                    initials.isNotEmpty ? initials : '?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.38,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
          ),
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.28,
              height: size * 0.28,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Выбор эмодзи ─────────────────────────────────────────────────

class EmojiPicker extends StatelessWidget {
  final String selected;
  final void Function(String emoji) onSelected;

  const EmojiPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const _emojis = [
    '😎',
    '🦊',
    '🐺',
    '🦁',
    '🐯',
    '🐻',
    '🐼',
    '🐨',
    '🦄',
    '🐲',
    '👾',
    '🤖',
    '👻',
    '💀',
    '🎭',
    '🧠',
    '🔥',
    '⚡',
    '🌊',
    '🌪️',
    '🎯',
    '💎',
    '🚀',
    '🛸',
    '🎮',
    '🎸',
    '🎺',
    '🎻',
    '🥷',
    '🧙',
    '🧛',
    '🧜',
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: _emojis.length,
      itemBuilder: (_, i) {
        final e = _emojis[i];
        final isSelected = e == selected;
        return GestureDetector(
          onTap: () => onSelected(e),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF1DB954).withValues(alpha: 0.2)
                  : Colors.grey.shade900,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: const Color(0xFF1DB954), width: 2)
                  : null,
            ),
            child: Center(
              child: Text(e, style: const TextStyle(fontSize: 22)),
            ),
          ),
        );
      },
    );
  }
}

// ── Выбор цвета фона аватара ────────────────────────────────────

class AvatarColorPicker extends StatelessWidget {
  final int selected;
  final void Function(int color) onSelected;

  const AvatarColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const _colors = [
    0xFF5C6BC0,
    0xFF26A69A,
    0xFFEF5350,
    0xFFAB47BC,
    0xFF42A5F5,
    0xFF66BB6A,
    0xFFFF7043,
    0xFFEC407A,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: _colors.map((c) {
        final isSelected = c == selected;
        return GestureDetector(
          onTap: () => onSelected(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border:
                  isSelected ? Border.all(color: Colors.white, width: 3) : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                          color: Color(c).withValues(alpha: 0.6), blurRadius: 8)
                    ]
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }
}
