import 'dart:async';
import 'package:flutter/foundation.dart';

/// Activity types for typing indicators
class Activity {
  static const int stopped = 0;
  static const int typing = 1;
  static const int recordingVideo = 2;
  static const int recordingVoice = 3;
  static const int sendingFile = 4;
}

/// Tracks remote peer typing/recording state.
/// UI listens to [activityFor] or [version] to rebuild.
class TypingService {
  TypingService._();
  static final TypingService instance = TypingService._();

  /// peerId → current activity (0=stopped, 1=typing, 2=video, 3=voice)
  final Map<String, int> _activities = {};
  /// Auto-clear timers (if no update in 5s, assume stopped)
  final Map<String, Timer> _timers = {};
  /// Bumped on every change — cheap way for UI to rebuild
  final ValueNotifier<int> version = ValueNotifier(0);

  int activityFor(String peerId) => _activities[peerId] ?? Activity.stopped;

  void update(String peerId, int activity) {
    _timers[peerId]?.cancel();
    if (activity == Activity.stopped) {
      _activities.remove(peerId);
      _timers.remove(peerId);
    } else {
      _activities[peerId] = activity;
      // Auto-clear after 6 seconds if no new update
      _timers[peerId] = Timer(const Duration(seconds: 6), () {
        _activities.remove(peerId);
        _timers.remove(peerId);
        version.value++;
      });
    }
    version.value++;
  }

  String label(int activity) {
    switch (activity) {
      case Activity.typing: return 'печатает...';
      case Activity.recordingVideo: return 'записывает видео...';
      case Activity.recordingVoice: return 'записывает голосовое...';
      case Activity.sendingFile: return 'отправляет файл...';
      default: return '';
    }
  }

  void dispose() {
    for (final t in _timers.values) { t.cancel(); }
    _timers.clear();
    _activities.clear();
  }
}
