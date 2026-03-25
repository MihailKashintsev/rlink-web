import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/story_service.dart';

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
  late AnimationController _progressCtrl;
  Timer? _timer;

  static const _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _progressCtrl = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );
    _startStory();
  }

  void _startStory() {
    _timer?.cancel();
    _progressCtrl.reset();
    final story = widget.stories[_index];
    StoryService.instance.markViewed(widget.authorId, story.id);
    _progressCtrl.forward();
    _timer = Timer(_storyDuration, _nextStory);
  }

  void _nextStory() {
    if (_index < widget.stories.length - 1) {
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

  @override
  void dispose() {
    _timer?.cancel();
    _progressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.stories[_index];
    final bgColor = Color(story.bgColor);

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
            // Story background
            story.imagePath != null && File(story.imagePath!).existsSync()
                ? Image.file(
                    File(story.imagePath!),
                    fit: BoxFit.cover,
                  )
                : Container(color: bgColor),

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

            // Story text
            if (story.text.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    story.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          blurRadius: 8,
                          color: Colors.black54,
                        ),
                      ],
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: List.generate(widget.stories.length, (i) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: i < _index
                                ? _ProgressBar(progress: 1.0)
                                : i == _index
                                    ? AnimatedBuilder(
                                        animation: _progressCtrl,
                                        builder: (_, __) => _ProgressBar(
                                          progress: _progressCtrl.value,
                                        ),
                                      )
                                    : _ProgressBar(progress: 0.0),
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
