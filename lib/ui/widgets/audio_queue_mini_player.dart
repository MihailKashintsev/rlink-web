import 'package:flutter/material.dart';

import '../../services/voice_service.dart';

/// Панель под системным статус-баром: очередь голосовых / аудио / квадратиков.
class AudioQueueMiniPlayer extends StatelessWidget {
  const AudioQueueMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ValueListenableBuilder<VoicePlaybackSession?>(
      valueListenable: VoiceService.instance.playbackSession,
      builder: (_, session, __) {
        if (session == null) return const SizedBox.shrink();

        IconData kindIcon;
        switch (session.kind) {
          case PlaybackMediaKind.voice:
            kindIcon = Icons.mic_none_rounded;
            break;
          case PlaybackMediaKind.audioFile:
            kindIcon = Icons.audio_file_outlined;
            break;
          case PlaybackMediaKind.squareVideo:
            kindIcon = Icons.videocam_outlined;
            break;
        }

        return Material(
          elevation: 3,
          color: cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(kindIcon, size: 20, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (session.total > 1)
                            Text(
                              '${session.indexOneBased} из ${session.total}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: session.isPaused ? 'Продолжить' : 'Пауза',
                      icon: Icon(
                        session.isPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      onPressed: () async {
                        if (session.isPaused) {
                          await VoiceService.instance.resumePlayback();
                        } else {
                          await VoiceService.instance.pausePlayback();
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Стоп',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () =>
                          VoiceService.instance.stopPlayback(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ValueListenableBuilder<double>(
                  valueListenable: VoiceService.instance.playProgress,
                  builder: (_, progress, __) {
                    final v = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: v,
                        minHeight: 3,
                        backgroundColor:
                            cs.onSurface.withValues(alpha: 0.12),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(cs.primary),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
