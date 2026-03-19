import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'gossip_router.dart';

const _kServiceUuid = '12345678-1234-5678-1234-56789abcdef0';
const _kTxCharUuid = '12345678-1234-5678-1234-56789abcdef1';

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  static const _method = MethodChannel('com.rendergames.rlink/ble');
  static const _events = EventChannel('com.rendergames.rlink/ble_events');
  static const _dataChannel = MethodChannel('com.rendergames.rlink/ble_data');

  final Map<DeviceIdentifier, BluetoothDevice> _connectedPeers = {};
  final Map<DeviceIdentifier, BluetoothCharacteristic> _txChars = {};
  final Set<DeviceIdentifier> _connecting = {};

  // BLE device ID → Ed25519 public key (заполняется при получении профиля)
  final Map<String, String> _bleIdToPublicKey = {};
  // Ed25519 public key → BLE device ID
  final Map<String, String> _publicKeyToBleId = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<dynamic>? _eventSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  bool _isRunning = false;
  bool _advertisingStarted = false;

  final ValueNotifier<int> peersCount = ValueNotifier(0);
  // Устройства подключены но профиль ещё не получен — показываем лоадер
  final ValueNotifier<Set<String>> pendingProfiles = ValueNotifier({});

  void Function(String peerId)? onPeerConnected;

  int get connectedPeersCount => _connectedPeers.length;

  /// Возвращает публичный ключ пира по его BLE ID (или сам BLE ID если ключ неизвестен)
  String resolvePublicKey(String bleId) => _bleIdToPublicKey[bleId] ?? bleId;

  // Вызывается когда профиль пира получен — убираем лоадер
  void markProfileReceived(String bleId) {
    if (pendingProfiles.value.contains(bleId)) {
      final upd = Set<String>.from(pendingProfiles.value)..remove(bleId);
      pendingProfiles.value = upd;
    }
  }

  /// Регистрирует маппинг BLE ID → публичный ключ
  void registerPeerKey(String bleId, String publicKey) {
    _bleIdToPublicKey[bleId] = publicKey;
    _publicKeyToBleId[publicKey] = bleId;
    debugPrint('[BLE] Mapped $bleId → ${publicKey.substring(0, 16)}...');
    peersCount.value = _connectedPeers.length; // триггерим UI обновление
  }

  /// Возвращает Bluetooth-имя устройства по его ID (BLE address или public key)
  String getDeviceName(String peerId) {
    // Если peerId — публичный ключ, найдём BLE ID
    final bleId = _publicKeyToBleId[peerId] ?? peerId;
    final device = _connectedPeers[DeviceIdentifier(bleId)];
    final name = device?.platformName ?? '';
    return name.isNotEmpty
        ? name
        : bleId.substring(0, bleId.length.clamp(0, 8));
  }

  /// Список пиров — возвращает публичные ключи если известны, иначе BLE ID
  List<String> get connectedPeerIds {
    return _connectedPeers.keys
        .map((id) => _bleIdToPublicKey[id.str] ?? id.str)
        .toSet()
        .toList();
  }

  /// Проверяет подключён ли пир (по публичному ключу или BLE ID)
  bool isPeerConnected(String peerId) {
    if (_publicKeyToBleId.containsKey(peerId)) {
      final bleId = _publicKeyToBleId[peerId]!;
      return _connectedPeers.containsKey(DeviceIdentifier(bleId));
    }
    return _connectedPeers.containsKey(DeviceIdentifier(peerId));
  }

  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    await _requestPermissions();
    await _waitForAdapter();

    _eventSub = _events.receiveBroadcastStream().listen(_onNativeEvent);
    // iOS push channel — native → Flutter via invokeMethod
    _dataChannel.setMethodCallHandler(_onDataChannelCall);
    await _startAdvertising();
    _startScan();
    _scheduleScanRestart();

    _adapterSub = FlutterBluePlus.adapterState.listen((state) async {
      if (state == BluetoothAdapterState.on && _isRunning) {
        debugPrint('[BLE] BT on — restarting');
        await Future.delayed(const Duration(seconds: 2));
        _advertisingStarted = false;
        await _startAdvertising();
        _startScan();
        _scheduleScanRestart();
      } else if (state == BluetoothAdapterState.off) {
        _advertisingStarted = false;
        _connectedPeers.clear();
        _txChars.clear();
        _connecting.clear();
        peersCount.value = 0;
      }
    });
  }

  Future<void> rescan() async {
    debugPrint('[BLE] Manual rescan');
    _startScan();
  }

  // Периодический рестарт сканирования — Android убивает lowLatency через ~30с
  Timer? _scanRestartTimer;
  void _scheduleScanRestart() {
    _scanRestartTimer?.cancel();
    _scanRestartTimer = Timer(const Duration(seconds: 25), () {
      if (_isRunning) {
        debugPrint('[BLE] Auto-restarting scan');
        _startScan();
        _scheduleScanRestart();
      }
    });
  }

  Future<void> _startAdvertising() async {
    if (_advertisingStarted) return;
    try {
      await _method.invokeMethod('startAdvertising');
      _advertisingStarted = true;
      debugPrint('[BLE] Advertising started');
    } catch (e) {
      debugPrint('[BLE] Advertising not available: $e');
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    _advertisingStarted = false;
    try {
      await _method.invokeMethod('stopAdvertising');
    } catch (_) {}
    _scanRestartTimer?.cancel();
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    await _eventSub?.cancel();
    await _adapterSub?.cancel();
    for (final d in List.from(_connectedPeers.values)) {
      await d.disconnect();
    }
    _connectedPeers.clear();
    _txChars.clear();
    _connecting.clear();
    peersCount.value = 0;
  }

  Future<void> broadcastPacket(GossipPacket packet) async {
    final bytes = packet.encode();
    if (Platform.isAndroid) {
      try {
        await _method.invokeMethod('sendPacket', {'data': bytes});
      } catch (_) {}
    }
    if (_txChars.isNotEmpty) {
      final futures = _txChars.values.map((c) => _writeChar(c, bytes));
      await Future.wait(futures, eagerError: false);
    }
  }

  Future<void> _onDataChannelCall(MethodCall call) async {
    debugPrint('[BLE] dataChannel call: ${call.method}');
    if (call.method == 'onBleData') {
      final args = call.arguments as Map<dynamic, dynamic>;
      final device = args['device'] as String? ?? 'native';
      final rawData = args['data'];
      if (rawData != null) {
        Uint8List bytes;
        if (rawData is Uint8List) {
          bytes = rawData;
        } else if (rawData is List) {
          bytes = Uint8List.fromList(List<int>.from(rawData));
        } else {
          debugPrint(
              '[BLE] dataChannel unknown data type: ${rawData.runtimeType}');
          return;
        }
        debugPrint('[BLE] dataChannel bytes=${bytes.length} from=$device');
        GossipRouter.instance.onPacketReceived(bytes, sourceId: device);
      }
    } else if (call.method == 'onAdvertisingStarted') {
      debugPrint('[BLE] Native advertising confirmed (via dataChannel)');
    }
  }

  void _onNativeEvent(dynamic event) {
    debugPrint(
        '[BLE] nativeEvent type=${event.runtimeType} val=${event.toString().substring(0, event.toString().length.clamp(0, 80))}');
    if (event is Map) {
      final type = event['type'] as String?;
      debugPrint('[BLE] nativeEvent map type=$type');
      if (type == 'data') {
        final device = event['device'] as String? ?? 'native';
        final rawData = event['data'];
        debugPrint(
            '[BLE] nativeEvent data from=$device rawType=${rawData.runtimeType}');
        if (rawData != null) {
          Uint8List bytes;
          if (rawData is Uint8List) {
            bytes = rawData;
          } else if (rawData is List) {
            bytes = Uint8List.fromList(List<int>.from(rawData));
          } else {
            // FlutterStandardTypedData or other — try to extract bytes
            try {
              final asList = rawData as dynamic;
              bytes = Uint8List.fromList(List<int>.from(asList.buffer != null
                  ? asList.buffer.asUint8List()
                  : asList));
            } catch (e) {
              debugPrint('[BLE] nativeEvent cannot convert data: $e');
              return;
            }
          }
          debugPrint('[BLE] nativeEvent bytes=${bytes.length} from=$device');
          GossipRouter.instance.onPacketReceived(bytes, sourceId: device);
        }
      } else if (type == 'advertising_started') {
        debugPrint('[BLE] Native advertising confirmed');
      }
    } else if (event is Uint8List || event is List) {
      final bytes = event is Uint8List
          ? event
          : Uint8List.fromList(List<int>.from(event as List));
      String sourceId = 'native';
      for (final id in _connectedPeers.keys) {
        if (!_bleIdToPublicKey.containsKey(id.str)) {
          sourceId = id.str;
          break;
        }
      }
      debugPrint(
          '[BLE] nativeEvent legacy bytes=${bytes.length} from=$sourceId');
      GossipRouter.instance.onPacketReceived(bytes, sourceId: sourceId);
    } else {
      debugPrint('[BLE] nativeEvent UNKNOWN type=${event.runtimeType}');
    }
  }

  void _startScan() {
    _scanSub?.cancel();
    try {
      FlutterBluePlus.startScan(
        withServices: [Guid(_kServiceUuid)],
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 15),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      debugPrint('[BLE] Start scan error: $e');
    }
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _onDeviceFound(r.device);
      }
    });
    debugPrint('[BLE] Scanning started');
  }

  Future<void> _onDeviceFound(BluetoothDevice device) async {
    if (_connectedPeers.containsKey(device.remoteId)) return;
    if (_connecting.contains(device.remoteId)) return;

    _connecting.add(device.remoteId);
    _connectedPeers[device.remoteId] = device;

    try {
      await device.connect(
          timeout: const Duration(seconds: 8), autoConnect: false);
      try {
        await device.requestMtu(512).timeout(const Duration(seconds: 5));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
      await _setupGattClient(device);
      peersCount.value = _connectedPeers.length;
      // Помечаем как ожидающий профиль
      final newPending = Set<String>.from(pendingProfiles.value)
        ..add(device.remoteId.str);
      pendingProfiles.value = newPending;
      debugPrint('[BLE] Connected to ${device.remoteId}');
      // Отправляем свой профиль
      onPeerConnected?.call(device.remoteId.str);
      // Таймаут: если профиль не пришёл за 5 сек — убираем лоадер
      Future.delayed(const Duration(seconds: 5), () {
        if (pendingProfiles.value.contains(device.remoteId.str)) {
          final upd = Set<String>.from(pendingProfiles.value)
            ..remove(device.remoteId.str);
          pendingProfiles.value = upd;
        }
      });
    } catch (e) {
      debugPrint('[BLE] Connect failed: $e');
      _connectedPeers.remove(device.remoteId);
      peersCount.value = _connectedPeers.length;
    } finally {
      _connecting.remove(device.remoteId);
    }

    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        final bleId = device.remoteId.str;
        // Убираем маппинг и pending при отключении
        final newPending = Set<String>.from(pendingProfiles.value)
          ..remove(bleId);
        pendingProfiles.value = newPending;
        final publicKey = _bleIdToPublicKey.remove(bleId);
        if (publicKey != null) _publicKeyToBleId.remove(publicKey);
        _connectedPeers.remove(device.remoteId);
        _txChars.remove(device.remoteId);
        peersCount.value = _connectedPeers.length;
        debugPrint('[BLE] Disconnected: $bleId');
        // Пробуем переподключиться через 3 секунды
        if (_isRunning) {
          Future.delayed(const Duration(seconds: 3), () {
            if (_isRunning && !_connectedPeers.containsKey(device.remoteId)) {
              _onDeviceFound(device);
            }
          });
        }
      }
    });
  }

  Future<void> _setupGattClient(BluetoothDevice device) async {
    final bleId = device.remoteId.str;
    final services = await device.discoverServices();
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != _kServiceUuid) continue;
      for (final char in service.characteristics) {
        if (char.uuid.toString().toLowerCase() != _kTxCharUuid) continue;
        await char.setNotifyValue(true);
        char.lastValueStream.listen((bytes) {
          if (bytes.isNotEmpty) {
            // Передаём BLE ID источника — нужен для маппинга профиля
            GossipRouter.instance.onPacketReceived(
              Uint8List.fromList(bytes),
              sourceId: bleId,
            );
          }
        });
        _txChars[device.remoteId] = char;
        debugPrint('[BLE] GATT ready for $bleId');
      }
    }
  }

  Future<void> _writeChar(BluetoothCharacteristic char, Uint8List bytes) async {
    // 490 bytes fits entire gossip packet (max ~440 bytes) in single write
    const mtu = 490;
    for (int offset = 0; offset < bytes.length; offset += mtu) {
      final end = (offset + mtu).clamp(0, bytes.length);
      final chunk = bytes.sublist(offset, end);
      try {
        await char
            .write(chunk, withoutResponse: false)
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[BLE] Write failed: $e');
        break;
      }
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
    await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(const Duration(seconds: 30));
  }
}
