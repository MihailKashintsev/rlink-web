import 'dart:async';

import 'app_settings.dart';
import 'gossip_router.dart' show GossipPacket;
import 'relay_service.dart';
import 'mesh_forwarder.dart';

/// Transport abstraction: routes gossip packets across available media.
abstract class PacketTransport {
  Future<void> forward(GossipPacket packet);
}

class DefaultPacketTransport implements PacketTransport {
  final MeshForwarder _meshForwarder = createMeshForwarder();

  static final RegExp _pubKeyHex = RegExp(r'^[0-9a-fA-F]{64}$');

  @override
  Future<void> forward(GossipPacket packet) async {
    final mode = AppSettings.instance.connectionMode;

    // 1) Local mesh forwarding (native only; no-op on web).
    await _meshForwarder.forward(packet, mode);

    // 2) Relay transport (works for mobile and web internet mode).
    if (RelayService.instance.isConnected && mode >= 1) {
      try {
        // Prefer explicit full recipient id when packet carries one.
        final explicitRecipient = packet.recipientId;
        final rid8 = packet.payload['r'] as String?;
        String? recipientKey;
        if (explicitRecipient != null &&
            _pubKeyHex.hasMatch(explicitRecipient.trim())) {
          recipientKey = explicitRecipient.trim().toLowerCase();
        } else if (rid8 != null) {
          recipientKey = RelayService.instance.findPeerByPrefix(rid8);
        }
        if (recipientKey != null && recipientKey.isNotEmpty) {
          await RelayService.instance.sendPacket(packet, recipientKey: recipientKey);
        } else {
          await RelayService.instance.broadcastPacket(packet);
        }
      } catch (_) {}
    }
  }
}
