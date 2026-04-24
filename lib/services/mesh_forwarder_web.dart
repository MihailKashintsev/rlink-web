import 'gossip_router.dart' show GossipPacket;
import 'mesh_forwarder.dart';

/// Web has no BLE/Wi-Fi mesh transport.
class _WebMeshForwarder implements MeshForwarder {
  @override
  Future<void> forward(GossipPacket packet, int mode) async {}
}

MeshForwarder createMeshForwarder() => _WebMeshForwarder();
