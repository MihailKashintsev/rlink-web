import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_storage_service.dart';
import 'outbound_dm_text.dart';

/// Периодически отправляет отложенные личные сообщения.
class ScheduledDmService {
  ScheduledDmService._();
  static final ScheduledDmService instance = ScheduledDmService._();

  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final due = await ChatStorageService.instance.getDueScheduledMessages(now);
      for (final row in due) {
        try {
          await OutboundDmText.send(
            peerId: row.peerId,
            fullText: row.text,
            replyToMessageId: row.replyToMessageId,
          );
          await ChatStorageService.instance.deleteScheduledDm(row.id);
        } catch (e) {
          debugPrint('[RLINK][SchedDM] skip ${row.id}: $e');
        }
      }
    } catch (e) {
      debugPrint('[RLINK][SchedDM] tick error: $e');
    }
  }
}
