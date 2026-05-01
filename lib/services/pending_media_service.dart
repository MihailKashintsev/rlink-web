import 'dart:typed_data';

/// Хранит входящие blob-ы, пропущенные из-за выключенной авто-загрузки.
/// UI может запросить обработку через [processBlob].
class PendingMediaService {
  PendingMediaService._();
  static final PendingMediaService instance = PendingMediaService._();

  final Map<String, _PendingBlob> _cache = {};

  /// Регистрируется из main.dart при инициализации.
  Future<void> Function(
    String fromId,
    String msgId,
    Uint8List data,
    bool isVoice,
    bool isVideo,
    bool isSquare,
    bool isFile,
    bool isSticker,
    String? fileName,
    bool viewOnce,
  )? _processor;

  void setProcessor(
    Future<void> Function(
      String fromId,
      String msgId,
      Uint8List data,
      bool isVoice,
      bool isVideo,
      bool isSquare,
      bool isFile,
      bool isSticker,
      String? fileName,
      bool viewOnce,
    ) fn,
  ) {
    _processor = fn;
  }

  void store({
    required String msgId,
    required Uint8List data,
    required String fromId,
    required bool isVoice,
    required bool isVideo,
    required bool isSquare,
    required bool isFile,
    required bool isSticker,
    required bool viewOnce,
    String? fileName,
  }) {
    _cache[msgId] = _PendingBlob(
      data: data,
      fromId: fromId,
      isVoice: isVoice,
      isVideo: isVideo,
      isSquare: isSquare,
      isFile: isFile,
      isSticker: isSticker,
      viewOnce: viewOnce,
      fileName: fileName,
    );
  }

  bool hasPending(String msgId) => _cache.containsKey(msgId);

  /// Обрабатывает отложенный blob (как будто авто-загрузка включена).
  /// Возвращает false если нет сохранённых данных или processor не задан.
  Future<bool> processBlob(String msgId) async {
    final blob = _cache.remove(msgId);
    if (blob == null) return false;
    final proc = _processor;
    if (proc == null) return false;
    await proc(
      blob.fromId,
      msgId,
      blob.data,
      blob.isVoice,
      blob.isVideo,
      blob.isSquare,
      blob.isFile,
      blob.isSticker,
      blob.fileName,
      blob.viewOnce,
    );
    return true;
  }

  void clear() => _cache.clear();
}

class _PendingBlob {
  final Uint8List data;
  final String fromId;
  final bool isVoice;
  final bool isVideo;
  final bool isSquare;
  final bool isFile;
  final bool isSticker;
  final bool viewOnce;
  final String? fileName;

  const _PendingBlob({
    required this.data,
    required this.fromId,
    required this.isVoice,
    required this.isVideo,
    required this.isSquare,
    required this.isFile,
    required this.isSticker,
    required this.viewOnce,
    this.fileName,
  });
}
