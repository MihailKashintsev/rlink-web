import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../services/chat_storage_service.dart';
import '../../services/gossip_router.dart';
import '../../services/image_service.dart';
import '../../services/media_upload_queue.dart';
import '../../services/relay_service.dart';
import '../../services/story_service.dart';
import '../widgets/reactions.dart';

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
  Uint8List? _webImageBytes;
  Uint8List? _webVideoBytes;
  VideoPlayerController? _videoCtrl;
  bool _publishing = false;

  // ── Text overlay (draggable) ──────────────────────────────────
  // Alignment units: -1.0 = far left/top, 1.0 = far right/bottom, 0 = center.
  double _textAlignX = 0;
  double _textAlignY = 0;
  double _textSize = 26.0;
  bool _textSizeSliderVisible = false;
  int _textColor = 0xFFFFFFFF;
  bool _textBold = true;
  bool _textItalic = false;
  double _textBgOpacity = 0.0;
  final List<StoryOverlayItem> _overlays = <StoryOverlayItem>[];
  int _activeOverlay = -1;

  Duration _videoTrimStart = Duration.zero;
  Duration _videoTrimEnd = Duration.zero;

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
  static const _textColors = [
    0xFFFFFFFF,
    0xFF111111,
    0xFFFFEB3B,
    0xFF80D8FF,
    0xFFFF8A80,
    0xFFC8E6C9,
  ];
  static const _stickerEmojis = [
    '✨', '🔥', '💥', '🎉', '💫', '🌈', '⚡', '🫶', '😎', '🚀', '💎', '🩵'
  ];

  void _cycleTextBgOpacity() {
    const steps = [0.0, 0.22, 0.38, 0.54];
    final idx = steps.indexWhere((v) => (_textBgOpacity - v).abs() < 0.01);
    final next = steps[(idx + 1) % steps.length];
    setState(() => _textBgOpacity = next);
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '${d.inMinutes}:$ss';
  }

  void _addOverlay(String value, {required bool isSticker}) {
    setState(() {
      _overlays.add(
        StoryOverlayItem(
          value: value,
          x: 0,
          y: 0,
          size: isSticker ? 42 : 36,
          isSticker: isSticker,
        ),
      );
      _activeOverlay = _overlays.length - 1;
    });
  }

  Future<void> _pickImage() async {
    if (kIsWeb) {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      final f = r?.files.firstOrNull;
      final bytes = f?.bytes;
      if (bytes == null) return;
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      setState(() {
        _imagePath = dataUrl;
        _videoPath = null;
        _webImageBytes = bytes;
        _webVideoBytes = null;
      });
      return;
    }
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
        _videoCtrl?.dispose();
        setState(() {
          _imagePath = picked.path;
          _videoPath = null;
          _videoCtrl = null;
          _webVideoBytes = null;
          _webImageBytes = null;
          _imageScale = 1.0;
          _imageDx = 0.0;
          _imageDy = 0.0;
        });
      }
    }
  }

  Future<void> _pickVideo() async {
    if (kIsWeb) {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        withData: true,
      );
      final f = r?.files.firstOrNull;
      final bytes = f?.bytes;
      if (bytes == null) return;
      final mime = f?.extension?.toLowerCase() == 'webm'
          ? 'video/webm'
          : 'video/mp4';
      final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(dataUrl));
      await ctrl.initialize();
      ctrl.setLooping(true);
      ctrl.play();
      _videoCtrl?.dispose();
      setState(() {
        _videoPath = dataUrl;
        _videoCtrl = ctrl;
        _imagePath = null;
        _webVideoBytes = bytes;
        _webImageBytes = null;
        _videoTrimStart = Duration.zero;
        _videoTrimEnd = ctrl.value.duration;
      });
      return;
    }
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
      _videoTrimStart = Duration.zero;
      _videoTrimEnd = ctrl.value.duration;
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
      _webImageBytes = null;
      _webVideoBytes = null;
      _videoTrimStart = Duration.zero;
      _videoTrimEnd = Duration.zero;
    });
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _imagePath == null && _videoPath == null) return;
    _publishing = true;

    String? savedImagePath;
    String? savedVideoPath;

    if (_imagePath != null && !kIsWeb) {
      try {
        savedImagePath = await ImageService.instance.compressAndSave(
          _imagePath!,
          maxSize: 480,
        );
      } catch (_) {
        savedImagePath = _imagePath!;
      }
    }

    if (_videoPath != null && !kIsWeb) {
      // Save compressed video to app storage
      savedVideoPath = await ImageService.instance.saveVideo(
        _videoPath!,
        isSquare: false,
        trimStart: _videoTrimStart,
        trimEnd: _videoTrimEnd,
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
      textColor: _textColor,
      textBold: _textBold,
      textItalic: _textItalic,
      textBgOpacity: _textBgOpacity,
      overlays: List<StoryOverlayItem>.from(_overlays),
    );
    StoryService.instance.addStory(story);

    // Close window immediately — broadcast runs in the background.
    if (mounted) Navigator.of(context).pop(story);
    unawaited(
      _broadcastStory(
        story,
        savedImagePath,
        savedVideoPath,
        webImageBytes: _webImageBytes,
        webVideoBytes: _webVideoBytes,
      ),
    );
  }

  Future<void> _broadcastStory(
    StoryItem story,
    String? savedImagePath,
    String? savedVideoPath,
    {Uint8List? webImageBytes,
    Uint8List? webVideoBytes,}
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
        textColor: story.textColor,
        textBold: story.textBold,
        textItalic: story.textItalic,
        textBgOpacity: story.textBgOpacity,
        overlays: story.overlays.map((e) => e.toJson()).toList(),
      );

      // ── Video blob path ────────────────────────────────────────
      // Используем MediaUploadQueue: гарантированная доставка с retry,
      // переживает оффлайн получателя и переподключение relay.
      if (kIsWeb && webVideoBytes != null && webVideoBytes.isNotEmpty) {
        try {
          final contacts = await ChatStorageService.instance.getContacts();
          final raw = ImageService.instance.compress(webVideoBytes);
          final blobMsgId = 'story_vid_${story.id}';
          for (final c in contacts) {
            if (raw.length <= 9 * 1024 * 1024) {
              await RelayService.instance.sendBlob(
                recipientKey: c.publicKeyHex,
                fromId: widget.authorId,
                msgId: blobMsgId,
                compressedData: raw,
                isVideo: true,
              );
            } else {
              const chunkSize = 220 * 1024;
              final total = (raw.length / chunkSize).ceil();
              for (var i = 0; i < total; i++) {
                final start = i * chunkSize;
                final end = (start + chunkSize < raw.length)
                    ? start + chunkSize
                    : raw.length;
                await RelayService.instance.sendBlobChunk(
                  recipientKey: c.publicKeyHex,
                  fromId: widget.authorId,
                  msgId: blobMsgId,
                  chunkIdx: i,
                  chunkTotal: total,
                  chunkData: Uint8List.sublistView(raw, start, end),
                  isVideo: true,
                );
              }
            }
          }
        } catch (e) {
          debugPrint('[RLINK][Story] Web video send failed: $e');
        }
        return;
      }
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

      if (kIsWeb && webImageBytes != null && webImageBytes.isNotEmpty) {
        try {
          final contacts = await ChatStorageService.instance.getContacts();
          final raw = ImageService.instance.compress(webImageBytes);
          final blobMsgId = 'story_${story.id}';
          for (final c in contacts) {
            if (raw.length <= 9 * 1024 * 1024) {
              await RelayService.instance.sendBlob(
                recipientKey: c.publicKeyHex,
                fromId: widget.authorId,
                msgId: blobMsgId,
                compressedData: raw,
              );
            } else {
              const chunkSize = 220 * 1024;
              final total = (raw.length / chunkSize).ceil();
              for (var i = 0; i < total; i++) {
                final start = i * chunkSize;
                final end = (start + chunkSize < raw.length)
                    ? start + chunkSize
                    : raw.length;
                await RelayService.instance.sendBlobChunk(
                  recipientKey: c.publicKeyHex,
                  fromId: widget.authorId,
                  msgId: blobMsgId,
                  chunkIdx: i,
                  chunkTotal: total,
                  chunkData: Uint8List.sublistView(raw, start, end),
                );
              }
            }
          }
        } catch (e) {
          debugPrint('[RLINK][Story] Web image send failed: $e');
        }
        return;
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
                                    child: kIsWeb
                                        ? Image.network(
                                            _imagePath!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                Container(
                                              color: Colors.grey.shade900,
                                              child: const Icon(
                                                Icons.broken_image_outlined,
                                                color: Colors.white38,
                                                size: 48,
                                              ),
                                            ),
                                          )
                                        : Image.file(
                                            File(_imagePath!),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, err, __) {
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
                                    color: (_textBgOpacity > 0)
                                        ? Colors.black.withValues(alpha: _textBgOpacity)
                                        : (_imagePath != null || _videoPath != null)
                                            ? Colors.black.withValues(alpha: 0.35)
                                            : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _textCtrl.text,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Color(_textColor),
                                      fontSize: _textSize,
                                      fontWeight:
                                          _textBold ? FontWeight.w700 : FontWeight.w500,
                                      fontStyle:
                                          _textItalic ? FontStyle.italic : FontStyle.normal,
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

                          for (var i = 0; i < _overlays.length; i++)
                            Align(
                              alignment: Alignment(_overlays[i].x, _overlays[i].y),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() => _activeOverlay = i),
                                onPanUpdate: (d) {
                                  final w = _canvasSize.width;
                                  final h = _canvasSize.height;
                                  setState(() {
                                    if (w > 0) {
                                      final nx = (_overlays[i].x + d.delta.dx / (w / 2))
                                          .clamp(-0.93, 0.93)
                                          .toDouble();
                                      _overlays[i] = StoryOverlayItem(
                                        value: _overlays[i].value,
                                        x: nx,
                                        y: _overlays[i].y,
                                        size: _overlays[i].size,
                                        isSticker: _overlays[i].isSticker,
                                      );
                                    }
                                    if (h > 0) {
                                      final ny = (_overlays[i].y + d.delta.dy / (h / 2))
                                          .clamp(-0.93, 0.93)
                                          .toDouble();
                                      _overlays[i] = StoryOverlayItem(
                                        value: _overlays[i].value,
                                        x: _overlays[i].x,
                                        y: ny,
                                        size: _overlays[i].size,
                                        isSticker: _overlays[i].isSticker,
                                      );
                                    }
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _activeOverlay == i
                                        ? Colors.white.withValues(alpha: 0.18)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _overlays[i].value,
                                    style: TextStyle(
                                      fontSize: _overlays[i].size,
                                      shadows: const [
                                        Shadow(
                                            blurRadius: 6, color: Colors.black54)
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
                  if (!kIsWeb &&
                      _videoCtrl != null &&
                      _videoCtrl!.value.isInitialized &&
                      _videoCtrl!.value.duration.inSeconds > 2) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.content_cut,
                                  size: 16, color: Colors.white70),
                              const SizedBox(width: 6),
                              Text(
                                'Фрагмент: ${_fmtDuration(_videoTrimStart)} - ${_fmtDuration(_videoTrimEnd)}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                          RangeSlider(
                            values: RangeValues(
                              _videoTrimStart.inSeconds.toDouble(),
                              _videoTrimEnd.inSeconds.toDouble().clamp(
                                  _videoTrimStart.inSeconds.toDouble() + 1,
                                  _videoCtrl!.value.duration.inSeconds.toDouble()),
                            ),
                            min: 0,
                            max: _videoCtrl!.value.duration.inSeconds.toDouble(),
                            divisions: _videoCtrl!.value.duration.inSeconds
                                .clamp(2, 240),
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            onChanged: (range) {
                              final start = Duration(
                                  seconds: range.start.floor().clamp(
                                      0, _videoCtrl!.value.duration.inSeconds - 1));
                              final end = Duration(
                                  seconds: range.end
                                      .floor()
                                      .clamp(start.inSeconds + 1,
                                          _videoCtrl!.value.duration.inSeconds));
                              setState(() {
                                _videoTrimStart = start;
                                _videoTrimEnd = end;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ..._textColors.map((c) {
                        final selected = c == _textColor;
                        return GestureDetector(
                          onTap: () => setState(() => _textColor = c),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected ? Colors.white : Colors.white30,
                                width: selected ? 2.2 : 1,
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Жирный',
                        onPressed: () => setState(() => _textBold = !_textBold),
                        icon: Icon(
                          Icons.format_bold,
                          color: _textBold ? Colors.amberAccent : Colors.white70,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Курсив',
                        onPressed: () =>
                            setState(() => _textItalic = !_textItalic),
                        icon: Icon(
                          Icons.format_italic,
                          color: _textItalic ? Colors.amberAccent : Colors.white70,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Подложка текста',
                        onPressed: _cycleTextBgOpacity,
                        icon: Icon(
                          Icons.rectangle_outlined,
                          color: _textBgOpacity > 0
                              ? Colors.amberAccent
                              : Colors.white70,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Добавить эмодзи',
                        onPressed: () async {
                          final emoji = await showReactionPickerSheet(context);
                          if (emoji != null && emoji.isNotEmpty) {
                            _addOverlay(emoji, isSticker: false);
                          }
                        },
                        icon: const Icon(Icons.emoji_emotions_outlined,
                            color: Colors.white70),
                      ),
                      IconButton(
                        tooltip: 'Добавить стикер',
                        onPressed: () async {
                          if (!mounted) return;
                          final emoji = await showModalBottomSheet<String>(
                            context: context,
                            backgroundColor: const Color(0xFF1C1C1E),
                            shape: const RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.vertical(top: Radius.circular(16)),
                            ),
                            builder: (ctx) => SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: _stickerEmojis
                                      .map((e) => GestureDetector(
                                            onTap: () =>
                                                Navigator.of(ctx).pop(e),
                                            child: Container(
                                              width: 48,
                                              height: 48,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: Colors.white10,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(e,
                                                  style: const TextStyle(
                                                      fontSize: 28)),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ),
                          );
                          if (emoji != null && emoji.isNotEmpty) {
                            _addOverlay(emoji, isSticker: true);
                          }
                        },
                        icon:
                            const Icon(Icons.auto_awesome, color: Colors.white70),
                      ),
                      if (_activeOverlay >= 0 && _activeOverlay < _overlays.length)
                        IconButton(
                          tooltip: 'Удалить стикер/эмодзи',
                          onPressed: () {
                            setState(() {
                              _overlays.removeAt(_activeOverlay);
                              _activeOverlay = -1;
                            });
                          },
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.white70),
                        ),
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
