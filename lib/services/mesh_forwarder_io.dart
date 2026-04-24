import 'dart:async';

import 'ble_service.dart';
import 'gossip_router.dart' show GossipPacket;
import 'mesh_forwarder.dart';
import 'wifi_direct_service.dart';

class _IoMeshForwarder implements MeshForwarder {
  @override
  Future<void> forward(GossipPacket packet, int mode) async {
    if (mode != 1) {
      await BleService.instance.broadcastPacket(packet);
    }
    if (mode == 2 && WifiDirectService.instance.isRunning) {
      unawaited(WifiDirectService.instance.sendToAll(packet.encode()));
    }
  }
}

MeshForwarder createMeshForwarder() => _IoMeshForwarder();
