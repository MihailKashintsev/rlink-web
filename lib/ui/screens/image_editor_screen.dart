import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point
// Usage:
//   final bytes = await Navigator.push<Uint8List>(
//     context, MaterialPageRoute(builder: (_) => ImageEditorScreen(imagePath: path)));
//   if (bytes != null) { /* send edited image */ }
// ─────────────────────────────────────────────────────────────────────────────

class ImageEditorScreen extends StatefulWidget {
  final String imagePath;
  const ImageEditorScreen({super.key, required this.imagePath});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

// ── Models ───────────────────────────────────────────────────────────────────

enum _Mode { draw, text, rotate, crop }

class _Stroke {
  final List<Offset> pts;
  final Color color;
  final double width;
  final bool eraser;
  const _Stroke(
      {required this.pts,
      required this.color,
      required this.width,
      this.eraser = false});
}

class _TextItem {
  String text;
  Offset pos;
  Color color;
  double size;
  _TextItem({required this.text, required this.pos, required this.color, required this.size});
}

// ── State ────────────────────────────────────────────────────────────────────

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  _Mode _mode = _Mode.draw;
  final _repaintKey = GlobalKey();

  // Draw
  final List<_Stroke> _strokes = [];
  final List<List<_Stroke>> _undoHistory = [];
  List<Offset> _currentPts = [];
  Color _penColor = Colors.white;
  double _penWidth = 5.0;
  bool _eraser = false;

  // Text
  final List<_TextItem> _texts = [];

  // Rotate
  int _rotateTurns = 0; // ×90°
  bool _flipH = false;

  // Crop (normalised 0–1 of the capture area)
  Rect _cropNorm = const Rect.fromLTWH(0, 0, 1, 1);

  bool _saving = false;

  static const _kPalette = [
    Colors.white,
    Colors.black,
    Color(0xFFFF4444),
    Color(0xFFFF9F43),
    Color(0xFFFFEA00),
    Color(0xFF00C853),
    Color(0xFF40C4FF),
    Color(0xFF7C4DFF),
  ];

  // ── Capture & crop ─────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2.5);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || !mounted) return;
      Uint8List bytes = data.buffer.asUint8List();

      if (_cropNorm != const Rect.fromLTWH(0, 0, 1, 1)) {
        bytes = await _crop(bytes, _cropNorm) ?? bytes;
      }

      if (mounted) Navigator.pop(context, bytes);
    } catch (e) {
      debugPrint('[ImageEditor] capture error: $e');
      if (mounted) Navigator.pop(context, null);
    }
  }

  static Future<Uint8List?> _crop(Uint8List png, Rect norm) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final iw = src.width.toDouble();
    final ih = src.height.toDouble();

    final srcRect =
        Rect.fromLTWH(norm.left * iw, norm.top * ih, norm.width * iw, norm.height * ih);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(src, srcRect,
        Rect.fromLTWH(0, 0, srcRect.width, srcRect.height), Paint());
    final pic = rec.endRecording();
    final cropped = await pic.toImage(srcRect.width.round(), srcRect.height.round());
    final bd = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  }

  // ── Draw gestures ──────────────────────────────────────────────────────────

  void _panStart(DragStartDetails d) {
    _undoHistory.add(List.from(_strokes));
    setState(() => _currentPts = [d.localPosition]);
  }

  void _panUpdate(DragUpdateDetails d) =>
      setState(() => _currentPts.add(d.localPosition));

  void _panEnd(DragEndDetails _) {
    if (_currentPts.isEmpty) return;
    setState(() {
      _strokes.add(_Stroke(
          pts: List.from(_currentPts),
          color: _penColor,
          width: _eraser ? _penWidth * 3 : _penWidth,
          eraser: _eraser));
      _currentPts = [];
    });
  }

  void _undo() {
    if (_undoHistory.isEmpty) return;
    setState(() {
      _strokes
        ..clear()
        ..addAll(_undoHistory.removeLast());
    });
  }

  // ── Text dialog ────────────────────────────────────────────────────────────

  Future<void> _addText(Offset pos) async {
    final ctrl = TextEditingController();
    Color col = Colors.white;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить текст'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Введите текст...'),
          ),
          const SizedBox(height: 12),
          StatefulBuilder(
            builder: (_, ss) => Wrap(
              spacing: 8,
              children: _kPalette
                  .map((c) => GestureDetector(
                        onTap: () => ss(() => col = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: col == c ? Colors.blue : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Добавить')),
        ],
      ),
    );

    if (result == true && ctrl.text.trim().isNotEmpty && mounted) {
      setState(() => _texts.add(_TextItem(
          text: ctrl.text.trim(), pos: pos, color: col, size: 26)));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
        actions: [
          if (_undoHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo, color: Colors.white),
              onPressed: _undo,
            ),
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2)),
                )
              : TextButton(
                  onPressed: _confirm,
                  child: const Text('Готово',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700)),
                ),
        ],
      ),
      body: Column(children: [
        // ── Editing canvas ────────────────────────────────────────────────
        Expanded(
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _mode == _Mode.draw ? _panStart : null,
              onPanUpdate: _mode == _Mode.draw ? _panUpdate : null,
              onPanEnd: _mode == _Mode.draw ? _panEnd : null,
              onTapUp: _mode == _Mode.text
                  ? (d) => _addText(d.localPosition)
                  : null,
              child: RepaintBoundary(
                key: _repaintKey,
                child: Stack(
                  fit: StackFit.passthrough,
                  clipBehavior: Clip.none,
                  children: [
                    // Image with rotation & flip
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..rotateZ(_rotateTurns * math.pi / 2)
                        ..multiply(Matrix4.diagonal3Values(
                            _flipH ? -1.0 : 1.0, 1.0, 1.0)),
                      child: Image.file(
                        File(widget.imagePath),
                        fit: BoxFit.contain,
                      ),
                    ),
                    // Drawing layer
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DrawPainter(
                          strokes: _strokes,
                          current: _currentPts,
                          currentColor: _penColor,
                          currentWidth: _eraser ? _penWidth * 3 : _penWidth,
                          currentEraser: _eraser,
                        ),
                      ),
                    ),
                    // Text items (draggable)
                    ..._texts.asMap().entries.map((e) {
                      final item = e.value;
                      return Positioned(
                        left: item.pos.dx - 60,
                        top: item.pos.dy - item.size / 2,
                        child: GestureDetector(
                          onPanUpdate: (d) =>
                              setState(() => item.pos += d.delta),
                          onDoubleTap: () async {
                            final ctrl = TextEditingController(text: item.text);
                            final result = await showDialog<String>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Изменить текст'),
                                content: TextField(controller: ctrl, autofocus: true),
                                actions: [
                                  TextButton(
                                      onPressed: () {
                                        setState(() => _texts.remove(item));
                                        Navigator.pop(ctx);
                                      },
                                      child: const Text('Удалить',
                                          style: TextStyle(color: Colors.red))),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, ctrl.text),
                                      child: const Text('OK')),
                                ],
                              ),
                            );
                            if (result != null && mounted) {
                              setState(() => item.text = result);
                            }
                          },
                          child: Text(
                            item.text,
                            style: TextStyle(
                              color: item.color,
                              fontSize: item.size,
                              fontWeight: FontWeight.bold,
                              shadows: const [
                                Shadow(blurRadius: 6, color: Colors.black87)
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),

        // ── Mode-specific toolbar ─────────────────────────────────────────
        _buildToolbar(),

        // ── Mode selector ─────────────────────────────────────────────────
        _buildModeBar(),
      ]),

      // Crop overlay (outside RepaintBoundary — UI chrome only)
      floatingActionButton: null,
    );
  }

  // Crop overlay rendered via Stack in the whole screen; we use an Overlay
  // approach instead so it sits above the RepaintBoundary.
  Widget _buildToolbar() {
    switch (_mode) {
      case _Mode.draw:
        return _DrawToolbar(
          colors: _kPalette,
          selected: _penColor,
          eraser: _eraser,
          width: _penWidth,
          onColorPick: (c) => setState(() {
            _penColor = c;
            _eraser = false;
          }),
          onEraserToggle: () => setState(() => _eraser = !_eraser),
          onWidthChange: (v) => setState(() => _penWidth = v),
        );
      case _Mode.text:
        return _TextHint(crop: _cropNorm);
      case _Mode.rotate:
        return _RotateToolbar(
          onLeft: () => setState(() => _rotateTurns = (_rotateTurns - 1) % 4),
          onRight: () => setState(() => _rotateTurns = (_rotateTurns + 1) % 4),
          onFlip: () => setState(() => _flipH = !_flipH),
        );
      case _Mode.crop:
        return _CropToolbar(
          onReset: () => setState(() => _cropNorm = const Rect.fromLTWH(0, 0, 1, 1)),
          onSquare: () => setState(() {
            final s = math.min(_cropNorm.width, _cropNorm.height);
            _cropNorm = Rect.fromCenter(center: _cropNorm.center, width: s, height: s);
          }),
          onWide: () => setState(() {
            const w = 0.9;
            _cropNorm = Rect.fromCenter(
                center: const Offset(0.5, 0.5), width: w, height: w * 9 / 16);
          }),
          crop: _cropNorm,
          onCropChanged: (r) => setState(() => _cropNorm = r),
        );
    }
  }

  Widget _buildModeBar() {
    const labels = ['Рисунок', 'Текст', 'Поворот', 'Кадр'];
    const icons = [Icons.brush, Icons.title, Icons.rotate_90_degrees_ccw, Icons.crop];
    return Container(
      height: 54,
      color: Colors.black,
      child: Row(
        children: List.generate(_Mode.values.length, (i) {
          final mode = _Mode.values[i];
          final sel = _mode == mode;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _mode = mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                color: sel ? Colors.white12 : Colors.transparent,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icons[i], color: sel ? Colors.white : Colors.white38, size: 20),
                  const SizedBox(height: 2),
                  Text(labels[i],
                      style: TextStyle(
                          color: sel ? Colors.white : Colors.white38,
                          fontSize: 10,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── Drawing custom painter ────────────────────────────────────────────────────

class _DrawPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final List<Offset> current;
  final Color currentColor;
  final double currentWidth;
  final bool currentEraser;

  const _DrawPainter({
    required this.strokes,
    required this.current,
    required this.currentColor,
    required this.currentWidth,
    required this.currentEraser,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    void drawPts(List<Offset> pts, Paint p) {
      if (pts.isEmpty) return;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, p);
    }

    for (final s in strokes) {
      final p = Paint()
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = s.eraser ? BlendMode.clear : BlendMode.srcOver;
      if (!s.eraser) p.color = s.color;
      drawPts(s.pts, p);
    }

    if (current.isNotEmpty) {
      final p = Paint()
        ..strokeWidth = currentWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = currentEraser ? BlendMode.clear : BlendMode.srcOver;
      if (!currentEraser) p.color = currentColor;
      drawPts(current, p);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawPainter o) => true;
}

// ── Toolbars ──────────────────────────────────────────────────────────────────

class _DrawToolbar extends StatelessWidget {
  final List<Color> colors;
  final Color selected;
  final bool eraser;
  final double width;
  final ValueChanged<Color> onColorPick;
  final VoidCallback onEraserToggle;
  final ValueChanged<double> onWidthChange;

  const _DrawToolbar({
    required this.colors,
    required this.selected,
    required this.eraser,
    required this.width,
    required this.onColorPick,
    required this.onEraserToggle,
    required this.onWidthChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Color dots
        ...colors.map((c) => GestureDetector(
              onTap: () => onColorPick(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 6),
                width: selected == c && !eraser ? 30 : 22,
                height: selected == c && !eraser ? 30 : 22,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected == c && !eraser ? Colors.white : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
            )),
        const Spacer(),
        // Eraser toggle
        GestureDetector(
          onTap: onEraserToggle,
          child: Icon(Icons.auto_fix_normal,
              size: 28, color: eraser ? Colors.white : Colors.white38),
        ),
        const SizedBox(width: 8),
        // Brush width slider
        SizedBox(
          width: 100,
          child: Slider(
            value: width,
            min: 2,
            max: 24,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: onWidthChange,
          ),
        ),
      ]),
    );
  }
}

class _TextHint extends StatelessWidget {
  final Rect crop;
  const _TextHint({required this.crop});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      alignment: Alignment.center,
      child: const Text(
        'Нажми на фото, чтобы добавить текст\nДважды нажми на текст, чтобы изменить',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white54, fontSize: 13),
      ),
    );
  }
}

class _RotateToolbar extends StatelessWidget {
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onFlip;

  const _RotateToolbar(
      {required this.onLeft, required this.onRight, required this.onFlip});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      color: Colors.black,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _Btn(Icons.rotate_left, '90° влево', onLeft),
        _Btn(Icons.rotate_right, '90° вправо', onRight),
        _Btn(Icons.flip, 'Зеркало', onFlip),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Btn(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: Colors.white, size: 28),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }
}

// ── Crop toolbar with interactive overlay ─────────────────────────────────────

class _CropToolbar extends StatelessWidget {
  final VoidCallback onReset;
  final VoidCallback onSquare;
  final VoidCallback onWide;
  final Rect crop;
  final ValueChanged<Rect> onCropChanged;

  const _CropToolbar({
    required this.onReset,
    required this.onSquare,
    required this.onWide,
    required this.crop,
    required this.onCropChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Interactive crop handles rendered over the image via Overlay
      // We use a LayoutBuilder-based widget embedded in a fixed-height row
      Container(
        height: 78,
        color: Colors.black,
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _Btn(Icons.crop_square, '1:1', onSquare),
          _Btn(Icons.crop_landscape, '16:9', onWide),
          _Btn(Icons.crop_free, 'Сбросить', onReset),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              '${(crop.width * 100).round()}×${(crop.height * 100).round()}%',
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

// ── Crop overlay (rendered as an Overlay entry above everything) ───────────────
// Used from outside _ImageEditorScreenState via a Stack over the editing canvas.

class _CropOverlay extends StatefulWidget {
  final Rect cropNorm;
  final ValueChanged<Rect> onChanged;
  const _CropOverlay({required this.cropNorm, required this.onChanged});

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

enum _CropHandle { tl, tr, bl, br }

class _CropOverlayState extends State<_CropOverlay> {
  _CropHandle? _active;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      final r = Rect.fromLTWH(widget.cropNorm.left * w, widget.cropNorm.top * h,
          widget.cropNorm.width * w, widget.cropNorm.height * h);

      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (d) => _active = _hit(d.localPosition, r),
        onPanUpdate: (d) {
          if (_active == null) return;
          final p = Offset(
            d.localPosition.dx.clamp(0.0, w),
            d.localPosition.dy.clamp(0.0, h),
          );
          Rect nr;
          const kMin = 40.0;
          switch (_active!) {
            case _CropHandle.tl:
              nr = Rect.fromLTRB(
                  p.dx.clamp(0, r.right - kMin),
                  p.dy.clamp(0, r.bottom - kMin),
                  r.right,
                  r.bottom);
            case _CropHandle.tr:
              nr = Rect.fromLTRB(
                  r.left,
                  p.dy.clamp(0, r.bottom - kMin),
                  p.dx.clamp(r.left + kMin, w),
                  r.bottom);
            case _CropHandle.bl:
              nr = Rect.fromLTRB(
                  p.dx.clamp(0, r.right - kMin),
                  r.top,
                  r.right,
                  p.dy.clamp(r.top + kMin, h));
            case _CropHandle.br:
              nr = Rect.fromLTRB(
                  r.left,
                  r.top,
                  p.dx.clamp(r.left + kMin, w),
                  p.dy.clamp(r.top + kMin, h));
          }
          widget.onChanged(Rect.fromLTRB(
              nr.left / w, nr.top / h, nr.right / w, nr.bottom / h));
        },
        onPanEnd: (_) => _active = null,
        child: CustomPaint(
          painter: _CropPainter(cropRect: r),
          size: Size(w, h),
        ),
      );
    });
  }

  _CropHandle? _hit(Offset p, Rect r) {
    const k = 32.0;
    if ((p - r.topLeft).distance < k) return _CropHandle.tl;
    if ((p - r.topRight).distance < k) return _CropHandle.tr;
    if ((p - r.bottomLeft).distance < k) return _CropHandle.bl;
    if ((p - r.bottomRight).distance < k) return _CropHandle.br;
    return null;
  }
}

class _CropPainter extends CustomPainter {
  final Rect cropRect;
  const _CropPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black54;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, cropRect.top), dim);
    canvas.drawRect(
        Rect.fromLTWH(0, cropRect.bottom, size.width, size.height - cropRect.bottom), dim);
    canvas.drawRect(
        Rect.fromLTWH(0, cropRect.top, cropRect.left, cropRect.height), dim);
    canvas.drawRect(
        Rect.fromLTWH(cropRect.right, cropRect.top, size.width - cropRect.right, cropRect.height),
        dim);

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(cropRect, border);

    // Rule-of-thirds grid
    final grid = Paint()
      ..color = Colors.white30
      ..strokeWidth = 0.6;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(
          Offset(cropRect.left + cropRect.width * i / 3, cropRect.top),
          Offset(cropRect.left + cropRect.width * i / 3, cropRect.bottom),
          grid);
      canvas.drawLine(
          Offset(cropRect.left, cropRect.top + cropRect.height * i / 3),
          Offset(cropRect.right, cropRect.top + cropRect.height * i / 3),
          grid);
    }

    // L-shaped corner handles
    const L = 18.0;
    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    for (final pt in [
      (cropRect.topLeft, const Offset(L, 0), const Offset(0, L)),
      (cropRect.topRight, const Offset(-L, 0), const Offset(0, L)),
      (cropRect.bottomLeft, const Offset(L, 0), const Offset(0, -L)),
      (cropRect.bottomRight, const Offset(-L, 0), const Offset(0, -L)),
    ]) {
      canvas.drawLine(pt.$1, pt.$1 + pt.$2, corner);
      canvas.drawLine(pt.$1, pt.$1 + pt.$3, corner);
    }
  }

  @override
  bool shouldRepaint(_CropPainter o) => o.cropRect != cropRect;
}
