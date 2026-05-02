import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../services/embedded_video_pause_bus.dart';
import 'square_video_recording_widgets.dart';

/// Предпросмотр «видеоквадратика» перед отправкой (удержание или полноэкранный рекордер).
/// [allowTrim] — показать ползунок обрезки (обычно true).
class HoldSquareVideoReviewScreen extends StatefulWidget {
  final String videoPath;
  final bool allowTrim;

  const HoldSquareVideoReviewScreen({
    super.key,
    required this.videoPath,
    required this.allowTrim,
  });

  @override
  State<HoldSquareVideoReviewScreen> createState() =>
      _HoldSquareVideoReviewScreenState();
}

class _HoldSquareVideoReviewScreenState
    extends State<HoldSquareVideoReviewScreen> {
  VideoPlayerController? _player;
  bool _ready = false;
  bool _busy = false;
  double _durationSec = 1;
  double _rangeStart = 0;
  double _rangeEnd = 1;
  int _embedPauseGen = 0;

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      try {
        _player?.pause();
      } catch (_) {}
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    final c = VideoPlayerController.file(File(widget.videoPath));
    _player = c;
    c.initialize().then((_) {
      if (!mounted) return;
      final d = c.value.duration.inMilliseconds / 1000.0;
      final dur = d > 0.05 ? d : 0.05;
      setState(() {
        _durationSec = dur;
        _rangeStart = 0;
        _rangeEnd = dur;
        _ready = true;
      });
      c.setLooping(true);
      c.play();
    });
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    _player?.dispose();
    super.dispose();
  }

  void _onRangeChanged(RangeValues v) {
    final p = _player;
    if (p == null || !_ready) return;
    setState(() {
      _rangeStart = v.start.clamp(0.0, _durationSec);
      _rangeEnd = v.end.clamp(0.0, _durationSec);
      if (_rangeEnd - _rangeStart < 0.25) {
        if (_rangeEnd >= _durationSec) {
          _rangeStart = (_rangeEnd - 0.25).clamp(0.0, _durationSec);
        } else {
          _rangeEnd = (_rangeStart + 0.25).clamp(0.0, _durationSec);
        }
      }
    });
    p.seekTo(Duration(milliseconds: (_rangeStart * 1000).round()));
  }

  bool get _effectivelyFullTrim {
    return _rangeStart <= 0.05 && _rangeEnd >= _durationSec - 0.05;
  }

  Future<void> _send() async {
    if (_busy || !_ready) return;
    final nav = Navigator.of(context);

    if (!widget.allowTrim || _effectivelyFullTrim) {
      nav.pop(widget.videoPath);
      return;
    }

    setState(() => _busy = true);
    try {
      final int st = _rangeStart
          .floor()
          .clamp(0, math.max(0, _durationSec.floor()))
          .toInt();
      var dur = (_rangeEnd - _rangeStart).ceil();
      if (dur < 1) dur = 1;
      final maxFromStart = (_durationSec - st).ceil();
      if (dur > maxFromStart) dur = math.max(1, maxFromStart);

      final info = await VideoCompress.compressVideo(
        widget.videoPath,
        quality: VideoQuality.MediumQuality,
        includeAudio: true,
        deleteOrigin: false,
        startTime: st,
        duration: dur,
      );
      if (!mounted) return;
      if (info?.path == null || info!.path!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось обрезать видео')),
        );
        setState(() => _busy = false);
        return;
      }
      nav.pop(info.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Обрезка: $e')),
        );
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _player;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Просмотр'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Отмена',
          onPressed: _busy ? null : () => Navigator.pop(context),
        ),
      ),
      body: !_ready || p == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (ctx, bc) {
                final side = math
                    .min(
                      squareVideoPreviewSize(ctx),
                      math.min(bc.maxWidth, bc.maxHeight) - 8,
                    )
                    .clamp(200.0, 360.0);
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: FittedBox(
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              child: SizedBox(
                                width: p.value.size.width,
                                height: p.value.size.height,
                                child: VideoPlayer(p),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.allowTrim) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'При необходимости выберите фрагмент или отправьте целиком',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      RangeSlider(
                        values: RangeValues(_rangeStart, _rangeEnd),
                        min: 0,
                        max: _durationSec,
                        onChanged: _busy ? null : _onRangeChanged,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${_rangeStart.toStringAsFixed(1)} с',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              '${_rangeEnd.toStringAsFixed(1)} с',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Проверьте кадр и нажмите «Отправить»',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _busy ? null : _send,
                            child: Text(_busy ? 'Обработка…' : 'Отправить'),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
