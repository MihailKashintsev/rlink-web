import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/story_service.dart';

/// Screen for creating a story: pick a color/photo and type text.
class StoryCreatorScreen extends StatefulWidget {
  final String authorId;

  const StoryCreatorScreen({super.key, required this.authorId});

  @override
  State<StoryCreatorScreen> createState() => _StoryCreatorScreenState();
}

class _StoryCreatorScreenState extends State<StoryCreatorScreen> {
  final _textCtrl = TextEditingController();
  int _bgColor = 0xFF6C5CE7;
  String? _imagePath;

  static const _colors = [
    0xFF6C5CE7,
    0xFFE91E63,
    0xFF2196F3,
    0xFF4CAF50,
    0xFFFF9800,
    0xFF009688,
    0xFF9C27B0,
    0xFFF44336,
    0xFF212121,
  ];

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1080,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _imagePath = picked.path);
    }
  }

  Future<void> _publish() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _imagePath == null) return;

    // Compress story image if present
    String? savedImagePath;
    if (_imagePath != null) {
      savedImagePath = await ImageService.instance.compressAndSave(
        _imagePath!,
        maxSize: 480,
      );
    }

    final story = StoryItem(
      id: const Uuid().v4(),
      authorId: widget.authorId,
      text: text,
      imagePath: savedImagePath,
      bgColor: _bgColor,
      createdAt: DateTime.now(),
    );
    StoryService.instance.addStory(story);
    await GossipRouter.instance.sendStory(
      storyId: story.id,
      authorId: story.authorId,
      text: story.text,
      bgColor: story.bgColor,
    );
    // Send story image via img_meta/img_chunk (broadcast)
    if (savedImagePath != null) {
      final bytes = await File(savedImagePath).readAsBytes();
      final chunks = ImageService.instance.splitToBase64Chunks(bytes);
      // Use story ID as link between story text and its image
      await GossipRouter.instance.sendImgMeta(
        msgId: story.id,
        totalChunks: chunks.length,
        fromId: widget.authorId,
        isAvatar: false,
      );
      await Future.delayed(const Duration(milliseconds: 100));
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendImgChunk(
          msgId: story.id,
          index: i,
          base64Data: chunks[i],
          fromId: widget.authorId,
        );
        if (i % 5 == 4) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }
    }
    if (mounted) Navigator.of(context).pop(story);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _publish,
            child: const Text(
              'Опубликовать',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Preview
          Expanded(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Color(_bgColor),
                  image: _imagePath != null
                      ? DecorationImage(
                          image: FileImage(File(_imagePath!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_imagePath != null)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.black38,
                        ),
                      ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TextField(
                          controller: _textCtrl,
                          textAlign: TextAlign.center,
                          maxLines: 5,
                          minLines: 1,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(blurRadius: 6, color: Colors.black54),
                            ],
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Введите текст...',
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Controls
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  // Color palette
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: _colors.map((c) {
                        final sel = c == _bgColor && _imagePath == null;
                        return GestureDetector(
                          onTap: () =>
                              setState(() {
                                _bgColor = c;
                                _imagePath = null;
                              }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 36,
                            height: 36,
                            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: sel
                                  ? Border.all(color: Colors.white, width: 3)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Photo button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: _pickImage,
                        icon: const Icon(Icons.photo_outlined),
                        label: const Text('Добавить фото'),
                      ),
                      if (_imagePath != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () => setState(() => _imagePath = null),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
