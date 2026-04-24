import 'ble_service.dart';
import 'relay_service.dart';

/// Shared lookup for peer crypto keys/public identities.
class PeerKeyDirectory {
  PeerKeyDirectory._();
  static final PeerKeyDirectory instance = PeerKeyDirectory._();

  static final _pk = RegExp(r'^[0-9a-fA-F]{64}$');

  String resolvePeerPublicKey(String peerIdOrBle) {
    final direct = peerIdOrBle.trim();
    if (_pk.hasMatch(direct)) return direct;
    final viaBle = BleService.instance.resolvePublicKey(direct);
    if (_pk.hasMatch(viaBle)) return viaBle;
    return direct;
  }

  String? getX25519(String publicKey) {
    final viaBle = BleService.instance.getPeerX25519Key(publicKey);
    if (viaBle != null && viaBle.isNotEmpty) return viaBle;
    final viaRelay = RelayService.instance.getPeerX25519Key(publicKey);
    if (viaRelay != null && viaRelay.isNotEmpty) return viaRelay;
    return null;
  }
}
