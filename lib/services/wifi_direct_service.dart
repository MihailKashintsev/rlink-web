import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'gossip_router.dart';

/// WiFi Direct transport layer using Google Nearby Connections API.
/// Работает параллельно с BLE — обеспечивает бо́льшую дальность (до 100м)
/// и более высокую пропускную способность.
class WifiDirectService {
  WifiDirectService._();
  static final WifiDirectService instance = WifiDirectService._();

  static const _serviceId = 'com.rendergames.rlink';
  static const _strategy = Strategy.P2P_CLUSTER;

  final ValueNotifier<int> peersCount = ValueNotifier(0);
  final Set<String> _connectedEndpoints = {};
  final Map<String, String> _endpointNames = {}; // endpointId → userName
  bool _isRunning = false;
  String _userName = 'Rlink';

  bool get isRunning => _isRunning;

  /// Запускает WiFi Direct discovery и advertising.
  Future<void> start({required String userName}) async {
    if (_isRunning) return;
    _userName = userName;

    // Request permissions (location + nearby WiFi devices for Android 13+)
    final perms = [
      Permission.location,
      Permission.nearbyWifiDevices,
    ];
    for (final p in perms) {
      final status = await p.status;
      if (!status.isGranted) {
        await p.request();
      }
    }

    // Check if location is enabled (required by Nearby Connections)
    final locEnabled = await Permission.location.serviceStatus;
    if (!locEnabled.isEnabled) {
      debugPrint('[WifiDirect] Location is disabled, cannot start');
      return;
    }

    try {
      _isRunning = true;
      await _startAdvertising();
      await _startDiscovery();
      debugPrint('[WifiDirect] Started (user: $_userName)');
    } catch (e) {
      debugPrint('[WifiDirect] Start error: $e');
      _isRunning = false;
    }
  }

  /// Останавливает WiFi Direct.
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      for (final id in _connectedEndpoints.toList()) {
        await Nearby().disconnectFromEndpoint(id);
      }
    } catch (e) {
      debugPrint('[WifiDirect] Stop error: $e');
    }
    _connectedEndpoints.clear();
    _endpointNames.clear();
    peersCount.value = 0;
  }

  /// Отправляет gossip-пакет всем подключённым WiFi Direct пирам.
  Future<void> sendToAll(Uint8List data) async {
    for (final id in _connectedEndpoints.toList()) {
      try {
        await Nearby().sendBytesPayload(id, data);
      } catch (e) {
        debugPrint('[WifiDirect] Send failed to $id: $e');
      }
    }
  }

  // ── Private ──────────────────────────────────────────────────

  Future<void> _startAdvertising() async {
    await Nearby().startAdvertising(
      _userName,
      _strategy,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      serviceId: _serviceId,
    );
  }

  Future<void> _startDiscovery() async {
    await Nearby().startDiscovery(
      _userName,
      _strategy,
      onEndpointFound: (endpointId, endpointName, serviceId) {
        debugPrint('[WifiDirect] Found: $endpointName ($endpointId)');
        // Auto-request connection
        Nearby().requestConnection(
          _userName,
          endpointId,
          onConnectionInitiated: _onConnectionInitiated,
          onConnectionResult: _onConnectionResult,
          onDisconnected: _onDisconnected,
        );
      },
      onEndpointLost: (endpointId) {
        debugPrint('[WifiDirect] Lost: $endpointId');
      },
      serviceId: _serviceId,
    );
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    debugPrint('[WifiDirect] Connection initiated: ${info.endpointName} ($endpointId)');
    _endpointNames[endpointId] = info.endpointName;
    // Auto-accept all connections (mesh network — everyone is trusted)
    Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: (endpointId, payload) {
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          // Feed received bytes into GossipRouter
          GossipRouter.instance.onPacketReceived(
            Uint8List.fromList(payload.bytes!),
            sourceId: 'wifi_$endpointId',
          );
        }
      },
      onPayloadTransferUpdate: (endpointId, update) {
        // Can track transfer progress if needed
      },
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      debugPrint('[WifiDirect] Connected: ${_endpointNames[endpointId]} ($endpointId)');
      _connectedEndpoints.add(endpointId);
      peersCount.value = _connectedEndpoints.length;
    } else {
      debugPrint('[WifiDirect] Connection failed: $endpointId (${status.name})');
      _endpointNames.remove(endpointId);
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint('[WifiDirect] Disconnected: $endpointId');
    _connectedEndpoints.remove(endpointId);
    _endpointNames.remove(endpointId);
    peersCount.value = _connectedEndpoints.length;
  }
}
