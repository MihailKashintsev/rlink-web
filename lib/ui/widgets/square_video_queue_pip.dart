import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/voice_service.dart';

/// Плавающее окно с квадратиком из очереди (можно перетаскивать).
class SquareVideoQueuePip extends StatefulWidget {
  const SquareVideoQueuePip({super.key});

  @override
  State<SquareVideoQueuePip> createState() => _SquareVideoQueuePipState();
}

class _SquareVideoQueuePipState extends State<SquareVideoQueuePip> {
  VideoPlayerController? _boundCtrl;
  double? _left;
  double? _bottom;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: VoiceService.instance.squareQueueVideoPreview,
      builder: (_, ctrl, __) {
        return ValueListenableBuilder<int>(
          valueListenable: VoiceService.instance.squareQueuePipLayoutRevision,
          builder: (_, __, ___) {
            return _buildPip(context, ctrl);
          },
        );
      },
    );
  }

  Widget _buildPip(BuildContext context, VideoPlayerController? ctrl) {
    if (ctrl != _boundCtrl) {
      _boundCtrl = ctrl;
      _left = null;
      _bottom = null;
    }
    if (ctrl == null) return const SizedBox.shrink();
    if (!VoiceService.instance.shouldDisplaySquareQueuePip()) {
      return const SizedBox.shrink();
    }

    final mq = MediaQuery.of(context);
    final size = mq.size;
    const pip = 112.0;
    final minBottom = mq.padding.bottom + 72;
    final rawMaxBottom = size.height - mq.padding.top - pip - 8;
    final maxBottom = rawMaxBottom < minBottom ? minBottom : rawMaxBottom;

    _left ??= (size.width - pip - 12).clamp(8.0, size.width - pip - 8);
    _bottom ??= minBottom + 56;

    final left = _left!.clamp(8.0, size.width - pip - 8);
    final bottom = _bottom!.clamp(minBottom, maxBottom);

    return Positioned(
      left: left,
      bottom: bottom,
      child: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          onPanUpdate: (d) {
            setState(() {
              _left = left + d.delta.dx;
              _bottom = bottom - d.delta.dy;
            });
          },
          child: SizedBox(
            width: pip,
            height: pip,
            child: VideoPlayer(ctrl),
          ),
        ),
      ),
    );
  }
}
