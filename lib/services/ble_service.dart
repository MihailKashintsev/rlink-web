import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'gossip_router.dart';

/// UUID сервиса MeshChat (генерируй свой уникальный для продакшна)
const _kServiceUuid = '12345678-1234-5678-1234-56789abcdef0';
/// Характеристика для передачи пакетов
const _kTxCharUuid  = '12345678-1234-5678-1234-56789abcdef1';
/// Характеристика для публичного ключа (advertise identity)
const _kIdCharUuid  = '12345678-1234-5678-1234-56789abcdef2';

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  final Map<DeviceIdentifier, BluetoothDevice> _connectedPeers = {};
  final Map<DeviceIdentifier, BluetoothCharacteristic> _txChars = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  bool _isRunning = false;

  /// Начать работу: запросить разрешения → advertising + scanning
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    await _requestPermissions();
    await _waitForAdapter();

    // Запускаем сканирование и GATT сервер параллельно
    _startScan();
    // Advertising на Android делается через flutter_blue_plus
    // На iOS advertising ограничен системой — работаем через scan response
    debugPrint('[BLE] Service started');
  }

  Future<void> stop() async {
    _isRunning = false;
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    await _adapterSub?.cancel();
    for (final device in _connectedPeers.values) {
      await device.disconnect();
    }
    _connectedPeers.clear();
    _txChars.clear();
  }

  /// Отправить пакет всем подключённым пирам
  Future<void> broadcastPacket(GossipPacket packet) async {
    final bytes = packet.encode();
    final futures = _txChars.values.map((char) => _writeChar(char, bytes));
    await Future.wait(futures, eagerError: false);
  }

  // ─── Сканирование и подключение ──────────────────────────

  void _startScan() {
    // Сканируем с фильтром по нашему ServiceUUID
    FlutterBluePlus.startScan(
      withServices: [Guid(_kServiceUuid)],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 30),
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _onDeviceFound(result.device);
      }
    });

    debugPrint('[BLE] Scanning started');
  }

  Future<void> _onDeviceFound(BluetoothDevice device) async {
    if (_connectedPeers.containsKey(device.remoteId)) return;

    _connectedPeers[device.remoteId] = device;
    debugPrint('[BLE] Found peer: ${device.remoteId}');

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      await _setupGattClient(device);
    } catch (e) {
      debugPrint('[BLE] Connect failed to ${device.remoteId}: $e');
      _connectedPeers.remove(device.remoteId);
    }

    // Следим за дисконнектом
    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connectedPeers.remove(device.remoteId);
        _txChars.remove(device.remoteId);
        debugPrint('[BLE] Peer disconnected: ${device.remoteId}');
      }
    });
  }

  Future<void> _setupGattClient(BluetoothDevice device) async {
    final services = await device.discoverServices();

    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != _kServiceUuid) continue;

      for (final char in service.characteristics) {
        final uuid = char.uuid.toString().toLowerCase();

        if (uuid == _kTxCharUuid) {
          // Подписываемся на нотификации (входящие пакеты)
          await char.setNotifyValue(true);
          char.lastValueStream.listen((bytes) {
            if (bytes.isNotEmpty) {
              GossipRouter.instance.onPacketReceived(Uint8List.fromList(bytes));
            }
          });
          // Сохраняем для исходящих
          _txChars[device.remoteId] = char;
        }
      }
    }

    debugPrint('[BLE] GATT client ready for ${device.remoteId}');
  }

  // ─── Утилиты ─────────────────────────────────────────────

  /// Записываем с автоматической разбивкой по MTU
  Future<void> _writeChar(BluetoothCharacteristic char, Uint8List bytes) async {
    const mtu = 200; // консервативно
    for (int offset = 0; offset < bytes.length; offset += mtu) {
      final chunk = bytes.sublist(
        offset,
        (offset + mtu).clamp(0, bytes.length),
      );
      await char.write(chunk, withoutResponse: false);
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location,
      ].request();
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    }
  }

  Future<void> _waitForAdapter() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return;

    debugPrint('[BLE] Waiting for adapter to turn on...');
    await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(const Duration(seconds: 30));
  }

  /// Количество подключённых пиров (для UI)
  int get connectedPeersCount => _connectedPeers.length;

  /// Stream состояния адаптера для UI
  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;
}
