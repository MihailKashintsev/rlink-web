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
  final double? latitude;
  final double? longitude;
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
    this.latitude,
    this.longitude,
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
        latitude: msg.latitude,
        longitude: msg.longitude,
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

/// Режим отправки в Эфир (меню на вкладке «Эфир»).
class EtherBroadcastOptions extends ChangeNotifier {
  EtherBroadcastOptions._();
  static final instance = EtherBroadcastOptions._();

  bool anonymous = true;
  bool attachGeo = false;
  double? customLatitude;
  double? customLongitude;

  bool get hasCustomLocation =>
      customLatitude != null && customLongitude != null;

  void setAnonymous(bool v) {
    if (anonymous == v) return;
    anonymous = v;
    notifyListeners();
  }

  void setAttachGeo(bool v) {
    if (attachGeo == v) return;
    attachGeo = v;
    notifyListeners();
  }

  void setCustomLocation({
    required double latitude,
    required double longitude,
  }) {
    customLatitude = latitude;
    customLongitude = longitude;
    notifyListeners();
  }

  void clearCustomLocation() {
    if (customLatitude == null && customLongitude == null) return;
    customLatitude = null;
    customLongitude = null;
    notifyListeners();
  }
}
