import 'dart:async';

import 'package:flutter/foundation.dart';

import 'name_filter.dart';

class EtherMessage {
  final String id;
  final String text;
  final int color;
  final DateTime receivedAt;
  final bool isOwn;
  // null = анонимно; non-null = открыто (содержит publicKeyHex отправителя)
  final String? senderId;
  final String? senderNick;
  // true if the message was filtered (contains a known name)
  final bool filtered;

  const EtherMessage({
    required this.id,
    required this.text,
    required this.color,
    required this.receivedAt,
    this.isOwn = false,
    this.senderId,
    this.senderNick,
    this.filtered = false,
  });
}

class EtherService {
  EtherService._();
  static final instance = EtherService._();

  final ValueNotifier<List<EtherMessage>> messages = ValueNotifier([]);
  final ValueNotifier<int> unreadCount = ValueNotifier(0);

  Timer? _cleanupTimer;

  void init() {
    _cleanupTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => cleanExpired());
  }

  void addMessage(EtherMessage msg) {
    cleanExpired();
    if (messages.value.any((m) => m.id == msg.id)) return;

    // Anti-bullying filter: if incoming message contains a known name,
    // replace text with a placeholder. Own messages are already filtered on send.
    final EtherMessage toAdd;
    if (!msg.isOwn && NameFilter.instance.detect(msg.text) != null) {
      debugPrint('[Ether] Filtered message containing name: ${msg.id}');
      toAdd = EtherMessage(
        id: msg.id,
        text: '[ сообщение скрыто — упоминание имени ]',
        color: msg.color,
        receivedAt: msg.receivedAt,
        isOwn: msg.isOwn,
        senderId: msg.senderId,
        senderNick: msg.senderNick,
        filtered: true,
      );
    } else {
      toAdd = msg;
    }

    messages.value = [toAdd, ...messages.value];
    if (!msg.isOwn) unreadCount.value++;
  }

  void markRead() => unreadCount.value = 0;

  void cleanExpired() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    final filtered =
        messages.value.where((m) => m.receivedAt.isAfter(cutoff)).toList();
    if (filtered.length != messages.value.length) {
      messages.value = filtered;
    }
  }

  void dispose() => _cleanupTimer?.cancel();
}
