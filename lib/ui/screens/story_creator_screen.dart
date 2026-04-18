import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../services/chat_storage_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/media_upload_queue.dart';
import '../../services/story_service.dart';

/// Story creator with draggable text overlay, pinch-to-zoom image, and text size control.
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
  String? _videoPath;
  VideoPlayerController? _videoCtrl;
  bool _publishing = false;

  // ── Text overlay (draggable) ──────────────────────────────────
  // Alignment units: -1.0 = far left/top, 1.0 = far right/bottom, 0 = center.
  double _textAlignX = 0;
  double _textAlignY = 0;
  double _textSize = 26.0;
  bool _textSizeSliderVisible = false;

  // ── Image transform (pinch-to-zoom + pan) ────────────────────
  double _imageScale = 1.0;
  double _imageDx = 0.0;
  double _imageDy = 0.0;
  // Gesture tracking for image
  double _scaleStart = 1.0;
  double _dxStart = 0.0;
  double _dyStart = 0.0;
  Offset _focalStart = Offset.zero;

  // Canvas size (set via LayoutBuilder for correct drag-to-alignment conversion)
  Size _canvasSize = Size.zero;

  static const _colors = [
    0xFF6C5CE7, 0xFFE91E63, 0xFF2196F3, 0xFF4CAF50,
    0xFFFF9800, 0xFF009688, 0xFF9C27B0, 0xFFF44336, 0xFF212121,
  ];

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1080,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null && picked.path.isNotEmpty) {
      // Verify the file actually exists before setting state
      if (File(picked.path).existsSync()) {
        setState(() {
          _imagePath = picked.path;
          _imageScale = 1.0;
          _imageDx = 0.0;
          _imageDy = 0.0;
        });
      }
    }
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: 30),
    );
    if (picked == null) return;
    // Init video player for preview
    final ctrl = VideoPlayerController.file(File(picked.path));
    await ctrl.initialize();
    ctrl.setLooping(true);
    ctrl.play();
    _videoCtrl?.dispose();
    setState(() {
      _videoPath = picked.path;
      _videoCtrl = ctrl;
      _imagePath = null; // video replaces photo
    });
  }

  void _clearMedia() {
    _videoCtrl?.dispose();
    setState(() {
      _imagePath = null;
      _videoPath = null;
      _videoCtrl = null;
      _imageScale = 1.0;
      _imageDx = 0.0;
      _imageDy = 0.0;
    });
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _imagePath == null && _videoPath == null) return;
    _publishing = true;

    String? savedImagePath;
    String? savedVideoPath;

    if (_imagePath != null) {
      savedImagePath = await ImageService.instance.compressAndSave(
        _imagePath!,
        maxSize: 480,
      );
    }

    if (_videoPath != null) {
      // Save compressed video to app storage
      savedVideoPath = await ImageService.instance.saveVideo(
        _videoPath!,
        isSquare: false,
      );
    }

    final story = StoryItem(
      id: const Uuid().v4(),
      authorId: widget.authorId,
      text: text,
      imagePath: savedImagePath,
      videoPath: savedVideoPath,
      bgColor: _bgColor,
      createdAt: DateTime.now(),
      textX: _textAlignX,
      textY: _textAlignY,
      textSize: _textSize,
    );
    StoryService.instance.addStory(story);

    // Close window immediately — broadcast runs in the background.
    if (mounted) Navigator.of(context).pop(story);
    unawaited(_broadcastStory(story, savedImagePath, savedVideoPath));
  }

  Future<void> _broadcastStory(
    StoryItem story,
    String? savedImagePath,
    String? savedVideoPath,
  ) async {
    try {
      await GossipRouter.instance.sendStory(
        storyId: story.id,
        authorId: story.authorId,
        text: story.text,
        bgColor: story.bgColor,
        textX: story.textX,
        textY: story.textY,
        textSize: story.textSize,
      );

      // ── Video blob path ────────────────────────────────────────
      // Используем MediaUploadQueue: гарантированная доставка с retry,
      // переживает оффлайн получателя и переподключение relay.
      if (savedVideoPath != null && File(savedVideoPath).existsSync()) {
        try {
          final contacts = await ChatStorageService.instance.getContacts();
          final blobMsgId = 'story_vid_${story.id}';
          for (final c in contacts) {
            unawaited(MediaUploadQueue.instance.enqueue(
              msgId: blobMsgId,
              filePath: savedVideoPath,
              recipientKey: c.publicKeyHex,
              fromId: widget.authorId,
              isVideo: true,
            ));
          }
          debugPrint('[RLINK][Story] Queued video for ${contacts.length} contacts');
        } catch (e) {
          debugPrint('[RLINK][Story] Video queue failed: $e');
        }
        return; // video story — skip image broadcast
      }

      if (savedImagePath == null) return;
      final file = File(savedImagePath);
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();

      // Картинка через MediaUploadQueue — переживает оффлайн получателя.
      try {
        final contacts = await ChatStorageService.instance.getContacts();
        final blobMsgId = 'story_${story.id}';
        for (final c in contacts) {
          unawaited(MediaUploadQueue.instance.enqueue(
            msgId: blobMsgId,
            filePath: savedImagePath,
            recipientKey: c.publicKeyHex,
            fromId: widget.authorId,
          ));
        }
        debugPrint('[RLINK][Story] Queued image for ${contacts.length} contacts');
      } catch (e) {
        debugPrint('[RLINK][Story] Image queue failed: $e');
      }

      // BLE img_meta/img_chunk broadcast
      try {
        final chunks = ImageService.instance.splitToBase64Chunks(bytes);
        await GossipRouter.instance.sendImgMeta(
          msgId: story.id,
          totalChunks: chunks.length,
          fromId: widget.authorId,
          isAvatar: false,
        );
        await Future.delayed(const Duration(milliseconds: 150));
        for (var i = 0; i < chunks.length; i++) {
          await GossipRouter.instance.sendImgChunk(
            msgId: story.id,
            index: i,
            base64Data: chunks[i],
            fromId: widget.authorId,
          );
          if (i % 5 == 4) await Future.delayed(const Duration(milliseconds: 30));
        }
        debugPrint('[RLINK][Story] BLE chunks sent: ${chunks.length}');
      } catch (e) {
        debugPrint('[RLINK][Story] BLE chunks failed: $e');
      }
    } catch (e) {
      debugPrint('[RLINK][Story] Broadcast failed: $e');
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPublish = !_publishing &&
        (_textCtrl.text.trim().isNotEmpty || _imagePath != null || _videoPath != null);

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  // Text size toggle
                  IconButton(
                    tooltip: 'Размер текста',
                    icon: Icon(
                      Icons.text_fields,
                      color: _textSizeSliderVisible
                          ? Colors.amberAccent
                          : Colors.white,
                    ),
                    onPressed: () => setState(
                        () => _textSizeSliderVisible = !_textSizeSliderVisible),
                  ),
                  const SizedBox(width: 4),
                  // Publish button
                  GestureDetector(
                    onTap: canPublish ? _publish : null,
                    child: AnimatedOpacity(
                      opacity: canPublish ? 1.0 : 0.4,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 9),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Text(
                          'Опубликовать',
                          style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),

            // ── Canvas (preview) ───────────────────────────────────
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    _canvasSize =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Background color
                          Container(color: Color(_bgColor)),

                          // Video preview layer
                          if (_videoCtrl != null &&
                              _videoCtrl!.value.isInitialized)
                            ClipRect(
                              child: SizedBox.expand(
                                child: FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _videoCtrl!.value.size.width,
                                    height: _videoCtrl!.value.size.height,
                                    child: VideoPlayer(_videoCtrl!),
                                  ),
                                ),
                              ),
                            ),

                          // Pinch-to-zoom image layer
                          if (_imagePath != null)
                            GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onScaleStart: (d) {
                                _scaleStart = _imageScale;
                                _dxStart = _imageDx;
                                _dyStart = _imageDy;
                                _focalStart = d.focalPoint;
                              },
                              onScaleUpdate: (d) {
                                final delta = d.focalPoint - _focalStart;
                                setState(() {
                                  _imageScale = (_scaleStart * d.scale)
                                      .clamp(0.5, 4.0);
                                  _imageDx = _dxStart + delta.dx;
                                  _imageDy = _dyStart + delta.dy;
                                });
                              },
                              child: Transform.translate(
                                offset: Offset(_imageDx, _imageDy),
                                child: Transform.scale(
                                  scale: _imageScale,
                                  child: SizedBox.expand(
                                    child: Image.file(
                                      File(_imagePath!),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, err, __) {
                                        // Path is stale/inaccessible — clear it
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                          if (mounted) _clearMedia();
                                        });
                                        return Container(
                                          color: Colors.grey.shade900,
                                          child: const Icon(
                                              Icons.broken_image_outlined,
                                              color: Colors.white38,
                                              size: 48),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Dark overlay when image or video is present (improves text contrast)
                          if (_imagePath != null || _videoPath != null)
                            Container(color: Colors.black.withValues(alpha: 0.15)),

                          // Draggable text overlay
                          if (_textCtrl.text.isNotEmpty)
                            Align(
                              alignment:
                                  Alignment(_textAlignX, _textAlignY),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (d) {
                                  final w = _canvasSize.width;
                                  final h = _canvasSize.height;
                                  setState(() {
                                    if (w > 0) {
                                      _textAlignX = (_textAlignX +
                                              d.delta.dx / (w / 2))
                                          .clamp(-0.93, 0.93);
                                    }
                                    if (h > 0) {
                                      _textAlignY = (_textAlignY +
                                              d.delta.dy / (h / 2))
                                          .clamp(-0.93, 0.93);
                                    }
                                  });
                                },
                                child: Container(
                                  constraints: BoxConstraints(
                                    maxWidth: _canvasSize.width * 0.84,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: (_imagePath != null || _videoPath != null)
                                        ? Colors.black.withValues(alpha: 0.35)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _textCtrl.text,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: _textSize,
                                      fontWeight: FontWeight.w600,
                                      shadows: const [
                                        Shadow(
                                            blurRadius: 6,
                                            color: Colors.black54),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Placeholder hint when text is empty
                          if (_textCtrl.text.isEmpty)
                            Center(
                              child: Text(
                                'Введите текст ниже',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 18,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),

                          // Text-size slider (vertical, right side)
                          if (_textSizeSliderVisible)
                            Positioned(
                              right: 4,
                              top: 40,
                              bottom: 40,
                              child: RotatedBox(
                                quarterTurns: -1,
                                child: SizedBox(
                                  width: _canvasSize.height - 80,
                                  child: Slider(
                                    value: _textSize,
                                    min: 14,
                                    max: 60,
                                    divisions: 23,
                                    activeColor: Colors.white,
                                    inactiveColor:
                                        Colors.white.withValues(alpha: 0.25),
                                    onChanged: (v) =>
                                        setState(() => _textSize = v),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),

            // ── Bottom controls ───────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Color palette
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: _colors.map((c) {
                        final sel = c == _bgColor && _imagePath == null;
                        return GestureDetector(
                          onTap: () {
                            _videoCtrl?.dispose();
                            setState(() {
                              _bgColor = c;
                              _imagePath = null;
                              _videoPath = null;
                              _videoCtrl = null;
                              _imageScale = 1.0;
                              _imageDx = 0.0;
                              _imageDy = 0.0;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 36,
                            height: 36,
                            margin: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: sel
                                  ? Border.all(color: Colors.white, width: 3)
                                  : Border.all(
                                      color: Colors.transparent, width: 3),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Text input field
                  TextField(
                    controller: _textCtrl,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    minLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Введите текст истории...',
                      hintStyle:
                          TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),

                  // Photo / Video / clear row
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
                        icon: const Icon(Icons.photo_outlined, size: 18),
                        label: const Text('Фото'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: _pickVideo,
                        icon: const Icon(Icons.videocam_outlined, size: 18),
                        label: const Text('Видео'),
                      ),
                      if (_imagePath != null || _videoPath != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _clearMedia,
                          icon: const Icon(Icons.close, color: Colors.white70),
                          tooltip: 'Убрать медиа',
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
