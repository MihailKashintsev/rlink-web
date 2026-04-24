import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/chat_storage_service.dart';
import '../../services/app_settings.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/story_service.dart';
import '../widgets/reactions.dart';

/// Full-screen story viewer with animated progress bar (Telegram/Instagram-style).
class StoryViewerScreen extends StatefulWidget {
  final String authorId;
  final String authorName;
  final List<StoryItem> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.authorId,
    required this.authorName,
    required this.stories,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  late int _index;
  late List<StoryItem> _stories;
  late AnimationController _progressCtrl;
  Timer? _timer;
  VideoPlayerController? _videoCtrl;

  static const _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _stories = List.from(widget.stories);
    _index = widget.initialIndex.clamp(0, (_stories.length - 1).clamp(0, 999));
    _progressCtrl = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );
    _startStory();
    StoryService.instance.version.addListener(_onStoryUpdate);
  }

  void _onStoryUpdate() {
    if (!mounted) return;
    final updated = StoryService.instance.storiesFor(widget.authorId);
    if (updated.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _stories = updated;
      if (_index >= _stories.length) {
        _index = _stories.length - 1;
        _startStory();
      }
    });
  }

  void _pauseStory() {
    _timer?.cancel();
    _progressCtrl.stop();
  }

  void _resumeStory() {
    if (!mounted) return;
    _progressCtrl.forward();
    final remaining =
        _storyDuration * (1.0 - _progressCtrl.value).clamp(0.0, 1.0).toDouble();
    _timer = Timer(remaining, _nextStory);
  }

  Future<void> _openReactionPicker() async {
    _pauseStory();
    final emoji = await showReactionPickerSheet(context);
    if (emoji != null) {
      final story = widget.stories[_index];
      final myId = CryptoService.instance.publicKeyHex;
      StoryService.instance.toggleReaction(story.id, emoji, myId);
      await GossipRouter.instance.sendReactionExt(
        kind: 'story',
        targetId: story.id,
        emoji: emoji,
        fromId: myId,
      );
    }
    if (mounted) _resumeStory();
  }

  Future<void> _startStory() async {
    _timer?.cancel();
    _progressCtrl.reset();
    if (_stories.isEmpty) return;

    // Dispose previous video controller
    final oldCtrl = _videoCtrl;
    _videoCtrl = null;
    oldCtrl?.dispose();

    final story = _stories[_index];
    StoryService.instance.markViewed(widget.authorId, story.id);

    // Notify the author that we viewed their story (skip for own stories)
    final myId = CryptoService.instance.publicKeyHex;
    if (story.authorId != myId && myId.isNotEmpty) {
      unawaited(GossipRouter.instance.sendStoryView(
        storyId: story.id,
        authorId: story.authorId,
        viewerId: myId,
      ));
    }

    // Init video player if story has a local video file
    if (story.videoPath != null && File(story.videoPath!).existsSync()) {
      final ctrl = VideoPlayerController.file(File(story.videoPath!));
      try {
        await ctrl.initialize();
        ctrl.setLooping(true);
        ctrl.play();
        if (mounted) {
          setState(() => _videoCtrl = ctrl);
        } else {
          ctrl.dispose();
          return;
        }
      } catch (e) {
        debugPrint('[StoryViewer] Video init error: $e');
        ctrl.dispose();
      }
    }

    _progressCtrl.forward();
    _timer = Timer(_storyDuration, _nextStory);
  }

  void _nextStory() {
    if (_index < _stories.length - 1) {
      setState(() => _index++);
      _startStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _prevStory() {
    if (_index > 0) {
      setState(() => _index--);
      _startStory();
    }
  }

  Future<void> _showViewersSheet(StoryItem story) async {
    _pauseStory();
    final viewers = List<String>.from(story.viewers);
    // Resolve viewer names from contacts DB
    final names = <String, String>{};
    for (final key in viewers) {
      final contact = await ChatStorageService.instance.getContact(key);
      names[key] = contact?.nickname ?? '${key.substring(0, 8)}…';
    }
    if (!mounted) {
      _resumeStory();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.visibility_outlined,
                      color: Colors.white70, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Просмотры: ${viewers.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (viewers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Пока никто не смотрел',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: viewers.length,
                  itemBuilder: (_, i) {
                    final key = viewers[i];
                    final name = names[key] ?? key.substring(0, 8);
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.white12,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ),
                      title: Text(
                        name,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (mounted) _resumeStory();
  }

  Future<void> _deleteCurrentStory() async {
    _pauseStory();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить историю?'),
        content: const Text('История будет удалена и больше не будет видна.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (mounted) _resumeStory();
      return;
    }
    final story = _stories[_index];
    StoryService.instance.deleteStory(story.id, widget.authorId);
    // Broadcast deletion so other devices remove it too
    unawaited(GossipRouter.instance.sendStoryDelete(
      storyId: story.id,
      authorId: widget.authorId,
    ));
    // _onStoryUpdate will handle pop or index adjustment automatically
  }

  @override
  void dispose() {
    StoryService.instance.version.removeListener(_onStoryUpdate);
    _timer?.cancel();
    _progressCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_stories.isEmpty) return const SizedBox.shrink();
    // Prefer live story from service so incoming reactions update UI.
    final baseStory = _stories[_index];
    final story = StoryService.instance.findStory(baseStory.id) ?? baseStory;
    final bgColor = Color(story.bgColor);
    final myId = CryptoService.instance.publicKeyHex;
    final isAuthor = story.authorId == myId;
    final showQuickBar = AppSettings.instance.showReactionsQuickBar;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: (details) {
          final width = MediaQuery.of(context).size.width;
          if (details.localPosition.dx < width / 2) {
            _prevStory();
          } else {
            _nextStory();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Story background — video, then image, then solid colour
            if (story.videoPath != null &&
                _videoCtrl != null &&
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
              )
            else if (story.imagePath != null &&
                File(story.imagePath!).existsSync())
              Image.file(File(story.imagePath!), fit: BoxFit.cover)
            else
              Container(color: bgColor),

            // Dark gradient overlay at top for progress bars
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.25],
                  colors: [Color(0x99000000), Colors.transparent],
                ),
              ),
            ),

            // Story text — positioned using textX/textY alignment from creator
            if (story.text.isNotEmpty)
              Align(
                alignment: Alignment(
                  story.textX.clamp(-1.0, 1.0),
                  story.textY.clamp(-1.0, 1.0),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: story.imagePath != null
                        ? BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(10),
                          )
                        : null,
                    child: Text(
                      story.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: story.textSize.clamp(14.0, 60.0),
                        fontWeight: FontWeight.w600,
                        shadows: const [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Top: progress bars + header
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Progress bars
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: List.generate(_stories.length, (i) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: i < _index
                                ? const _ProgressBar(progress: 1.0)
                                : i == _index
                                    ? AnimatedBuilder(
                                        animation: _progressCtrl,
                                        builder: (_, __) => _ProgressBar(
                                          progress: _progressCtrl.value,
                                        ),
                                      )
                                    : const _ProgressBar(progress: 0.0),
                          ),
                        );
                      }),
                    ),
                  ),

                  // Author header
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Text(
                          widget.authorName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black54)
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _timeAgo(story.createdAt),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        if (isAuthor)
                          GestureDetector(
                            onTap: _deleteCurrentStory,
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.delete_outline,
                                  color: Colors.white, size: 20),
                            ),
                          ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: const Icon(Icons.close,
                              color: Colors.white, size: 24),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom bar: reactions (author sees counter, viewer sees react button).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: false,
                child: SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xAA000000), Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        if (isAuthor) ...[
                          // Author: view count (tappable → shows viewer list)
                          GestureDetector(
                            onTap: () => _showViewersSheet(story),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.visibility_outlined,
                                      color: Colors.white, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${story.viewers.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Author: aggregate reaction counter
                          if (story.totalReactions > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.favorite,
                                      color: Colors.white, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${story.totalReactions}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (story.totalReactions > 0)
                            const SizedBox(width: 10),
                          if (story.reactions.isNotEmpty)
                            Flexible(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ReactionsBar(
                                  reactions: story.reactions,
                                  myId: myId,
                                  onTap: (_) {},
                                  compact: true,
                                ),
                              ),
                            ),
                        ] else ...[
                          // Viewer: quick reactions + full picker
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  if (showQuickBar)
                                    for (final e in kQuickReactionEmojis)
                                      GestureDetector(
                                        onTap: () async {
                                          _pauseStory();
                                          final story2 = widget.stories[_index];
                                          StoryService.instance.toggleReaction(
                                              story2.id, e, myId);
                                          await GossipRouter.instance
                                              .sendReactionExt(
                                            kind: 'story',
                                            targetId: story2.id,
                                            emoji: e,
                                            fromId: myId,
                                          );
                                          if (mounted) _resumeStory();
                                        },
                                        child: Container(
                                          margin:
                                              const EdgeInsets.only(right: 6),
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: story.reactions[e]
                                                        ?.contains(myId) ==
                                                    true
                                                ? Colors.white
                                                    .withValues(alpha: 0.28)
                                                : Colors.white
                                                    .withValues(alpha: 0.12),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Text(e,
                                              style: const TextStyle(
                                                  fontSize: 22)),
                                        ),
                                      ),
                                  GestureDetector(
                                    onTap: _openReactionPicker,
                                    child: Container(
                                      margin: EdgeInsets.only(
                                          left: showQuickBar ? 2 : 0),
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.add,
                                          color: Colors.white, size: 22),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин';
    return '${diff.inHours} ч';
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: Colors.white38,
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        minHeight: 3,
      ),
    );
  }
}
