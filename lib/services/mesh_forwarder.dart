import 'gossip_router.dart' show GossipPacket;
import 'mesh_forwarder_io.dart'
    if (dart.library.html) 'mesh_forwarder_web.dart' as impl;

/// Platform-specific local-mesh forwarding (BLE/Wi-Fi Direct).
abstract class MeshForwarder {
  Future<void> forward(GossipPacket packet, int mode);
}

MeshForwarder createMeshForwarder() => impl.createMeshForwarder();
