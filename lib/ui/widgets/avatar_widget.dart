import 'dart:io';
import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as epf;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/app_settings.dart';
import '../../services/image_service.dart';
import '../../services/runtime_platform.dart';

enum AvatarPresenceTransport { bluetooth, internet, wifiDirect }

class AvatarWidget extends StatelessWidget {
  final String initials;
  final int color;
  final String emoji; // если не пустой — показываем эмодзи вместо инициалов
  final String? imagePath; // если задан — показываем фото поверх всего
  final double size;
  final bool isOnline;
  final List<AvatarPresenceTransport> onlineTransports;
  final bool hasStory; // показывать ли кольцо сторис
  final bool hasUnviewedStory; // непросмотренная сторис — яркий градиент

  const AvatarWidget({
    super.key,
    required this.initials,
    required this.color,
    this.emoji = '',
    this.imagePath,
    this.size = 48,
    this.isOnline = false,
    this.onlineTransports = const [],
    this.hasStory = false,
    this.hasUnviewedStory = false,
  });

  @override
  Widget build(BuildContext context) {
    // Resolve potentially stale iOS sandbox path
    final raw = imagePath;
    final resolvedPath = ImageService.instance.resolveStoredPath(raw);
    final String networkPath = resolvedPath != null &&
            (resolvedPath.startsWith('http://') ||
                resolvedPath.startsWith('https://') ||
                resolvedPath.startsWith('blob:') ||
                resolvedPath.startsWith('data:'))
        ? resolvedPath
        : (raw != null &&
                (raw.startsWith('http://') ||
                    raw.startsWith('https://') ||
                    raw.startsWith('blob:') ||
                    raw.startsWith('data:'))
            ? raw
            : '');
    final file = !kIsWeb &&
            resolvedPath != null &&
            !resolvedPath.startsWith('http://') &&
            !resolvedPath.startsWith('https://')
        ? File(resolvedPath)
        : null;
    final hasImage = file != null && file.existsSync();
    final hasNetworkImage = networkPath.isNotEmpty;

    // If story ring is shown, shrink the avatar by 6px so the ring fits within size
    final ringWidth = hasStory ? 3.0 : 0.0;
    final gap = hasStory ? 2.0 : 0.0;
    // Guard against negative/zero size to prevent NaN in CoreGraphics
    final innerSize = math.max(size - (ringWidth + gap) * 2, 1.0);

    Widget avatar = Container(
      width: innerSize,
      height: innerSize,
      decoration: BoxDecoration(
        color: Color(color),
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: hasImage
            ? Image.file(
                file,
                width: innerSize,
                height: innerSize,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child: emoji.isNotEmpty
                      ? Text(emoji, style: TextStyle(fontSize: innerSize * 0.46))
                      : Text(
                          initials.isNotEmpty ? initials : '?',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: innerSize * 0.38,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                ),
              )
            : hasNetworkImage
                ? Image.network(
                    networkPath,
                    width: innerSize,
                    height: innerSize,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(
                      child: emoji.isNotEmpty
                          ? Text(emoji,
                              style: TextStyle(fontSize: innerSize * 0.46))
                          : Text(
                              initials.isNotEmpty ? initials : '?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: innerSize * 0.38,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                    ),
                  )
            : Center(
                child: emoji.isNotEmpty
                    ? Text(emoji, style: TextStyle(fontSize: innerSize * 0.46))
                    : Text(
                        initials.isNotEmpty ? initials : '?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: innerSize * 0.38,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
              ),
      ),
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (hasStory)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hasUnviewedStory
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFE91E63),
                          Color(0xFFFF9800),
                          Color(0xFFFFEB3B)
                        ],
                      )
                    : LinearGradient(
                        colors: [Colors.grey.shade500, Colors.grey.shade700],
                      ),
              ),
            ),
          if (hasStory)
            Container(
              width: innerSize + gap * 2,
              height: innerSize + gap * 2,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                shape: BoxShape.circle,
              ),
            ),
          avatar,
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.46,
                height: size * 0.28,
                padding: EdgeInsets.symmetric(horizontal: size * 0.03),
                decoration: BoxDecoration(
                  color: AppSettings.instance.onlineStatusColor,
                  borderRadius: BorderRadius.circular(size * 0.2),
                  border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _statusIcons(size),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _statusIcons(double avatarSize) {
    final iconSize = avatarSize * 0.12;
    final icons = <IconData>[];
    for (final t in onlineTransports) {
      switch (t) {
        case AvatarPresenceTransport.bluetooth:
          icons.add(Icons.bluetooth);
          break;
        case AvatarPresenceTransport.internet:
          icons.add(Icons.public);
          break;
        case AvatarPresenceTransport.wifiDirect:
          icons.add(Icons.wifi);
          break;
      }
    }
    final selected = icons.take(2).toList();
    if (selected.isEmpty) {
      selected.add(Icons.circle);
    }
    final out = <Widget>[];
    for (var i = 0; i < selected.length; i++) {
      out.add(Icon(selected[i], size: iconSize, color: Colors.white));
      if (i != selected.length - 1) {
        out.add(SizedBox(width: avatarSize * 0.012));
      }
    }
    return out;
  }
}

// ── Выбор эмодзи (полный набор Unicode через emoji_picker_flutter) ──

class AvatarEmojiPicker extends StatelessWidget {
  final String selected;
  final void Function(String emoji) onSelected;

  const AvatarEmojiPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final useNoto =
        RuntimePlatform.isAndroid && AppSettings.instance.useIosStyleEmoji;
    return SizedBox(
      height: 280,
      child: epf.EmojiPicker(
        onEmojiSelected: (_, emoji) => onSelected(emoji.emoji),
        config: epf.Config(
          height: 280,
          checkPlatformCompatibility: !useNoto,
          emojiTextStyle:
              useNoto ? GoogleFonts.notoColorEmoji(fontSize: 26) : null,
          emojiViewConfig: const epf.EmojiViewConfig(
            backgroundColor: Color(0xFF1A1A1A),
            columns: 8,
            emojiSizeMax: 26,
          ),
          categoryViewConfig: const epf.CategoryViewConfig(
            backgroundColor: Color(0xFF1A1A1A),
            iconColorSelected: Color(0xFF1DB954),
            indicatorColor: Color(0xFF1DB954),
            iconColor: Colors.grey,
          ),
          bottomActionBarConfig: const epf.BottomActionBarConfig(
            backgroundColor: Color(0xFF1A1A1A),
            buttonIconColor: Colors.grey,
          ),
          searchViewConfig: const epf.SearchViewConfig(
            backgroundColor: Color(0xFF1A1A1A),
            buttonIconColor: Colors.grey,
          ),
        ),
      ),
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
