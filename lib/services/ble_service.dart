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

  bool get _isWindows => !kIsWeb && Platform.isWindows;
  bool get _isLinux => !kIsWeb && Platform.isLinux;
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool get _isMacOS => !kIsWeb && Platform.isMacOS;

  static const _method = MethodChannel('com.rendergames.rlink/ble');
  static const _events = EventChannel('com.rendergames.rlink/ble_events');
  static const _dataChannel = MethodChannel('com.rendergames.rlink/ble_data');

  final Map<DeviceIdentifier, BluetoothDevice> _connectedPeers = {};
  final Map<DeviceIdentifier, BluetoothCharacteristic> _txChars = {};
  final Set<DeviceIdentifier> _connecting = {};
  // BLE centrals that connected TO us (subscribed to our peripheral characteristic).
  // Tracked so isDirectBleId() works for both directions of GATT connection.
  final Set<String> _connectedCentralIds = {};

  // BLE device ID → Ed25519 public key (заполняется при получении профиля)
  final Map<String, String> _bleIdToPublicKey = {};
  // Ed25519 public key → BLE device ID
  final Map<String, String> _publicKeyToBleId = {};
  // Ed25519 public key → X25519 public key base64 (для E2E шифрования)
  final Map<String, String> _x25519Keys = {};
  // BLE device ID → last known RSSI (for radar distance estimation)
  final Map<String, int> _rssiValues = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<dynamic>? _eventSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  // FrameBuffer for legacy raw bytes path in _onNativeEvent (fallback)
  final _nativeFrameBuf = _FrameBuffer();

  bool _isRunning = false;
  bool _advertisingStarted = false;

  // Keep-alive: периодически ре-броадкастим свой профиль всем пирам
  Timer? _keepAliveTimer;

  final ValueNotifier<int> peersCount = ValueNotifier(0);
  // Устройства подключены но профиль ещё не получен — показываем лоадер
  final ValueNotifier<Set<String>> pendingProfiles = ValueNotifier({});
  // Инкрементируется при каждом registerPeerKey — для надёжного уведомления UI
  final ValueNotifier<int> peerMappingsVersion = ValueNotifier(0);

  // Exchange state per peer: 0=connected, 1=profile_sent, 2=profile_received, 3=complete
  final ValueNotifier<Map<String, int>> exchangeStates = ValueNotifier({});
  // Incoming pair requests: bleId → {nick, color, emoji}
  final ValueNotifier<Map<String, Map<String, dynamic>>> incomingPairRequests = ValueNotifier({});

  void setExchangeState(String peerId, int state) {
    final upd = Map<String, int>.from(exchangeStates.value);
    upd[peerId] = state;
    exchangeStates.value = upd;
  }

  void addPairRequest(String bleId, Map<String, dynamic> info) {
    final upd = Map<String, Map<String, dynamic>>.from(incomingPairRequests.value);
    upd[bleId] = info;
    incomingPairRequests.value = upd;
  }

  void removePairRequest(String bleId) {
    final upd = Map<String, Map<String, dynamic>>.from(incomingPairRequests.value);
    upd.remove(bleId);
    incomingPairRequests.value = upd;
  }

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

  /// Сбрасывает маппинги BLE ID ↔ публичный ключ (для полного сброса)
  void clearMappings() {
    _bleIdToPublicKey.clear();
    _publicKeyToBleId.clear();
    _x25519Keys.clear();
    debugPrint('[RLINK][BLE] Key mappings cleared');
    peerMappingsVersion.value++;
  }

  /// Регистрирует X25519 публичный ключ пира (для E2E шифрования).
  void registerPeerX25519Key(String publicKey, String x25519KeyBase64) {
    if (x25519KeyBase64.isNotEmpty) {
      _x25519Keys[publicKey] = x25519KeyBase64;
    }
  }

  /// Возвращает X25519 публичный ключ пира (base64) или null если неизвестен.
  String? getPeerX25519Key(String publicKey) => _x25519Keys[publicKey];

  /// Возвращает последний известный RSSI для пира (по publicKey или BLE ID).
  int? getRssi(String peerId) {
    final direct = _rssiValues[peerId];
    if (direct != null) return direct;
    final bleId = _publicKeyToBleId[peerId];
    return bleId != null ? _rssiValues[bleId] : null;
  }

  /// Повторно запрашивает профили для всех уже подключённых устройств.
  /// Вызывается после clearMappings() чтобы загрузить профили заново.
  Future<void> refreshProfiles() async {
    if (_connectedPeers.isEmpty) return;
    // Добавляем все подключённые устройства в pending
    final newPending = Set<String>.from(pendingProfiles.value);
    for (final id in _connectedPeers.keys) {
      newPending.add(id.str);
    }
    pendingProfiles.value = newPending;
    peerMappingsVersion.value++;
    // Повторно отправляем свой профиль — пиры ответят своими
    for (final id in _connectedPeers.keys) {
      onPeerConnected?.call(id.str);
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Снимает устройство из pending и сбрасывает его маппинг для переподключения
  void resetPeerMapping(String peerId) {
    final bleId = _publicKeyToBleId[peerId] ?? peerId;
    if (bleId.isNotEmpty) {
      _bleIdToPublicKey.remove(bleId);
      _publicKeyToBleId.remove(peerId);
      final upd = Set<String>.from(pendingProfiles.value)..add(bleId);
      pendingProfiles.value = upd;
      peerMappingsVersion.value++;
      debugPrint('[RLINK][BLE] Reset mapping for $peerId (BLE: $bleId)');
    }
  }

  final Map<String, Timer> _retryTimers = {};

  void _updatePeersCount() {
    peersCount.value = connectedPeerIds.length;
  }

  /// Регистрирует маппинг BLE ID → публичный ключ
  void registerPeerKey(String bleId, String publicKey) {
    final oldPublicKey = _bleIdToPublicKey[bleId];
    if (oldPublicKey != null && oldPublicKey != publicKey) {
      _publicKeyToBleId.remove(oldPublicKey);
    }
    _bleIdToPublicKey[bleId] = publicKey;
    _publicKeyToBleId[publicKey] = bleId;
    markProfileReceived(bleId);
    _retryTimers[bleId]?.cancel();
    _retryTimers.remove(bleId);
    setExchangeState(bleId, 2); // profile_received
    setExchangeState(publicKey, 3); // complete
    debugPrint('[RLINK][BLE] Mapped $bleId → ${publicKey.substring(0, 16)}...');

    // Кросс-регистрация: одно физическое устройство появляется в двух ролях —
    // как peripheral (в _connectedPeers, BLE-сканирование) и как central
    // (_connectedCentralIds, входящее подключение к нашему peripheral).
    // Gossip-дедупликация блокирует повторную обработку того же профиля,
    // поэтому только одна сторона регистрирует ключ. Если в другом наборе
    // ровно одна запись без маппинга — это тот же девайс, регистрируем тоже.
    _crossRegister(bleId, publicKey);

    _updatePeersCount();
    peerMappingsVersion.value++;
  }

  void _crossRegister(String bleId, String publicKey) {
    if (_connectedCentralIds.contains(bleId)) {
      // Profile came from central side → register ALL unmapped peripherals
      // that appeared around the same time (most likely the same physical device).
      final unmapped = _connectedPeers.keys
          .where((id) => !_bleIdToPublicKey.containsKey(id.str))
          .toList();
      // If there's only one unmapped peripheral, it's almost certainly this device.
      // If there are multiple, register the most recently added one (last in map order).
      if (unmapped.length == 1) {
        final pid = unmapped.first.str;
        _bleIdToPublicKey[pid] = publicKey;
        markProfileReceived(pid);
        debugPrint('[RLINK][BLE] Cross-registered peripheral $pid → ${publicKey.substring(0, 16)}');
      } else if (unmapped.length > 1) {
        // Multiple unmapped — register the last one (most recently connected)
        final pid = unmapped.last.str;
        _bleIdToPublicKey[pid] = publicKey;
        markProfileReceived(pid);
        debugPrint('[RLINK][BLE] Cross-registered peripheral (last of ${unmapped.length}) $pid → ${publicKey.substring(0, 16)}');
      }
    } else if (_connectedPeers.containsKey(DeviceIdentifier(bleId))) {
      // Profile came from peripheral side → register ALL unmapped centrals
      final unmapped = _connectedCentralIds
          .where((id) => !_bleIdToPublicKey.containsKey(id))
          .toList();
      if (unmapped.length == 1) {
        final cid = unmapped.first;
        _bleIdToPublicKey[cid] = publicKey;
        markProfileReceived(cid);
        debugPrint('[RLINK][BLE] Cross-registered central $cid → ${publicKey.substring(0, 16)}');
      } else if (unmapped.length > 1) {
        // Multiple unmapped — register the last one (most recently connected)
        final cid = unmapped.last;
        _bleIdToPublicKey[cid] = publicKey;
        markProfileReceived(cid);
        debugPrint('[RLINK][BLE] Cross-registered central (last of ${unmapped.length}) $cid → ${publicKey.substring(0, 16)}');
      }
    }
  }

  /// Registers ALL currently unmapped BLE IDs (both peripheral and central) to the
  /// given public key. Call this after pair exchange when we know there's only one
  /// other physical device, so any unmapped ID must belong to it.
  void registerPeerKeyForAllRoles(String publicKey) {
    // Register all unmapped peripherals
    for (final id in _connectedPeers.keys) {
      if (!_bleIdToPublicKey.containsKey(id.str)) {
        _bleIdToPublicKey[id.str] = publicKey;
        markProfileReceived(id.str);
        debugPrint('[RLINK][BLE] registerPeerKeyForAllRoles: peripheral ${id.str} → ${publicKey.substring(0, 16)}');
      }
    }
    // Register all unmapped centrals
    for (final id in _connectedCentralIds.toList()) {
      if (!_bleIdToPublicKey.containsKey(id)) {
        _bleIdToPublicKey[id] = publicKey;
        markProfileReceived(id);
        debugPrint('[RLINK][BLE] registerPeerKeyForAllRoles: central $id → ${publicKey.substring(0, 16)}');
      }
    }
    _updatePeersCount();
    peerMappingsVersion.value++;
  }

  /// Force-clears all pending entries for a public key (and its BLE IDs).
  /// Called after successful pair exchange to ensure UI doesn't show stale pending state.
  void clearPendingForPublicKey(String publicKey) {
    final bleId = _publicKeyToBleId[publicKey];
    final upd = Set<String>.from(pendingProfiles.value);
    upd.remove(publicKey);
    if (bleId != null) upd.remove(bleId);
    // Also check all connected peers for this key
    for (final id in _connectedPeers.keys) {
      if (_bleIdToPublicKey[id.str] == publicKey) upd.remove(id.str);
    }
    for (final id in _connectedCentralIds) {
      if (_bleIdToPublicKey[id] == publicKey) upd.remove(id);
    }
    if (upd.length != pendingProfiles.value.length) {
      pendingProfiles.value = upd;
      debugPrint('[RLINK][BLE] Cleared pending for $publicKey (${pendingProfiles.value.length} remaining)');
    }
  }

  /// Возвращает true если профиль пира ещё не получен (загружается)
  /// Проверяет и по BLE ID, и по публичному ключу
  bool isPeerProfilePending(String peerId) {
    if (pendingProfiles.value.contains(peerId)) return true;
    final bleId = _publicKeyToBleId[peerId];
    return bleId != null && pendingProfiles.value.contains(bleId);
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

  /// Список пиров — возвращает публичные ключи если известны, иначе BLE ID.
  /// Включает как устройства, к которым подключились мы (central), так и те что подключились к нам (peripheral).
  List<String> get connectedPeerIds {
    final ids = <String>{};
    for (final id in _connectedPeers.keys) {
      ids.add(_bleIdToPublicKey[id.str] ?? id.str);
    }
    for (final id in _connectedCentralIds) {
      ids.add(_bleIdToPublicKey[id] ?? id);
    }
    return ids.toList();
  }

  /// Проверяет, является ли bleId прямым (физически подключённым) устройством.
  /// Учитывает оба направления: мы подключились к ним (central) или они к нам (peripheral).
  bool isDirectBleId(String bleId) =>
      _connectedPeers.containsKey(DeviceIdentifier(bleId)) ||
      _connectedCentralIds.contains(bleId);

  /// Проверяет подключён ли пир (по публичному ключу или BLE ID).
  /// Учитывает оба направления подключения.
  bool isPeerConnected(String peerId) {
    if (_connectedPeers.containsKey(DeviceIdentifier(peerId))) return true;
    if (_connectedCentralIds.contains(peerId)) return true;
    if (_publicKeyToBleId.containsKey(peerId)) {
      final bleId = _publicKeyToBleId[peerId]!;
      return _connectedPeers.containsKey(DeviceIdentifier(bleId)) ||
          _connectedCentralIds.contains(bleId);
    }
    for (final id in _connectedPeers.keys) {
      if (_bleIdToPublicKey[id.str] == peerId) return true;
    }
    for (final id in _connectedCentralIds) {
      if (_bleIdToPublicKey[id] == peerId) return true;
    }
    return false;
  }

  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  Future<void> start() async {
    if (_isRunning) return;
    if (kIsWeb) {
      _isRunning = false;
      return;
    }
    _isRunning = true;

    // BLE не поддерживается на Windows/Linux — работаем только на мобильных и macOS
    if (_isWindows || _isLinux) {
      final os = Platform.operatingSystem;
      debugPrint('[RLINK][BLE] BLE not supported on $os, skipping');
      _isRunning = false;
      return;
    }

    await _requestPermissions();
    await _waitForAdapter();

    _eventSub = _events.receiveBroadcastStream().listen(_onNativeEvent);
    // iOS/macOS push channel — native → Flutter via invokeMethod
    _dataChannel.setMethodCallHandler(_onDataChannelCall);
    // Просим AppDelegate сбросить буферизованные события
    Future.delayed(const Duration(milliseconds: 500), () async {
      try {
        await _method.invokeMethod('flushPendingEvents');
      } catch (_) {}
    });
    await _startAdvertising();
    _startScan();
    _scheduleScanRestart();
    _scheduleKeepAlive();

    _adapterSub = FlutterBluePlus.adapterState.listen((state) async {
      if (state == BluetoothAdapterState.on && _isRunning) {
        debugPrint('[RLINK][BLE] BT on — restarting');
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
        _connectedCentralIds.clear();
        peersCount.value = 0;
      }
    });
  }

  Future<void> rescan() async {
    if (kIsWeb) return;
    debugPrint('[RLINK][BLE] Manual rescan');
    _startScan();
  }

  // Периодический рестарт сканирования — Android убивает lowLatency через ~30с
  Timer? _scanRestartTimer;
  void _scheduleScanRestart() {
    _scanRestartTimer?.cancel();
    _scanRestartTimer = Timer(const Duration(seconds: 60), () {
      if (_isRunning) {
        debugPrint('[RLINK][BLE] Auto-restarting scan');
        _startScan();
        _scheduleScanRestart();
      }
    });
  }

  // Периодический keep-alive: обновляем peers count
  void _scheduleKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_isRunning) return;
      _updatePeersCount();
      debugPrint('[RLINK][BLE] Keep-alive: ${connectedPeerIds.length} peer(s)');
    });
  }

  Future<void> _startAdvertising() async {
    if (_advertisingStarted) return;
    try {
      await _method.invokeMethod('startAdvertising');
      _advertisingStarted = true;
      debugPrint('[RLINK][BLE] Advertising started');
    } catch (e) {
      debugPrint('[RLINK][BLE] Advertising not available: $e');
    }
  }

  Future<void> stop() async {
    if (kIsWeb) {
      _isRunning = false;
      _advertisingStarted = false;
      _scanRestartTimer?.cancel();
      _keepAliveTimer?.cancel();
      _scanRestartTimer = null;
      _keepAliveTimer = null;
      _connectedPeers.clear();
      _txChars.clear();
      _connecting.clear();
      _connectedCentralIds.clear();
      peersCount.value = 0;
      return;
    }
    _isRunning = false;
    _advertisingStarted = false;
    if (!kIsWeb && !_isWindows && !_isLinux) {
      try {
        await _method.invokeMethod('stopAdvertising');
      } catch (_) {}
    }
    _scanRestartTimer?.cancel();
    _keepAliveTimer?.cancel();
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
    _connectedCentralIds.clear();
    peersCount.value = 0;
  }

  Future<void> broadcastPacket(GossipPacket packet) async {
    if (kIsWeb) return;
    final bytes = packet.encode();
    if (_isAndroid || _isIOS || _isMacOS) {
      // Notify subscribed Centrals via native peripheral manager
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
        GossipRouter.instance.onPacketReceived(bytes, sourceId: device);
      }
    } else if (call.method == 'onAdvertisingStarted') {
      debugPrint('[RLINK][BLE] Native advertising confirmed (via dataChannel)');
    } else if (call.method == 'onCentralSubscribed') {
      final centralId = call.arguments as String? ?? '';
      if (centralId.isNotEmpty) {
        _connectedCentralIds.add(centralId);
        final newPending = Set<String>.from(pendingProfiles.value)..add(centralId);
        pendingProfiles.value = newPending;
        _updatePeersCount();
        onPeerConnected?.call(centralId);
        debugPrint('[RLINK][BLE] Central subscribed (dataChannel): $centralId');
      }
    } else if (call.method == 'onCentralUnsubscribed') {
      final centralId = call.arguments as String? ?? '';
      if (centralId.isNotEmpty) {
        _connectedCentralIds.remove(centralId);
        _updatePeersCount();
      }
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is Map) {
      final type = event['type'] as String?;
      if (type == 'data') {
        final device = event['device'] as String? ?? 'native';
        final rawData = event['data'];
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
              debugPrint('[RLINK][BLE] nativeEvent cannot convert data: $e');
              return;
            }
          }
          GossipRouter.instance.onPacketReceived(bytes, sourceId: device);
        }
      } else if (type == 'advertising_started') {
        debugPrint('[RLINK][BLE] Native advertising confirmed');
      } else if (type == 'central_subscribed') {
        final centralId = event['device'] as String? ?? '';
        if (centralId.isNotEmpty) {
          _connectedCentralIds.add(centralId);
          final newPending = Set<String>.from(pendingProfiles.value)..add(centralId);
          pendingProfiles.value = newPending;
          _updatePeersCount();
          onPeerConnected?.call(centralId);
          debugPrint('[RLINK][BLE] Central subscribed: $centralId');
        }
      } else if (type == 'central_unsubscribed') {
        final centralId = event['device'] as String? ?? '';
        if (centralId.isNotEmpty) {
          _connectedCentralIds.remove(centralId);
          final newPending = Set<String>.from(pendingProfiles.value)..remove(centralId);
          pendingProfiles.value = newPending;
          _updatePeersCount();
          debugPrint('[RLINK][BLE] Central unsubscribed: $centralId');
        }
      }
    } else if (event is Uint8List || event is List) {
      // Legacy raw bytes path (Android used to send raw chunks here).
      // Now Android sends Map events with type/device/data, but keep this
      // as fallback with _FrameBuffer reassembly for safety.
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
      for (final packet in _nativeFrameBuf.feed(bytes)) {
        GossipRouter.instance.onPacketReceived(packet, sourceId: sourceId);
      }
    } else {
      debugPrint('[RLINK][BLE] nativeEvent UNKNOWN type=${event.runtimeType}');
    }
  }

  void _startScan() {
    _scanSub?.cancel();
    try {
      // Both platforms pass withServices AND withNames.
      // flutter_blue_plus ORs multiple scan filters, so devices matching
      // EITHER criteria are returned. This lets both platforms find:
      //   • Devices advertising service UUID (foreground)
      //   • Devices advertising name "Rlink" (background iOS, some Android)
      FlutterBluePlus.startScan(
        withServices: [Guid(_kServiceUuid)],
        withNames: ['Rlink'],
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 15),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      debugPrint('[RLINK][BLE] Start scan error: $e');
    }
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _rssiValues[r.device.remoteId.str] = r.rssi;
        _onDeviceFound(r.device);
      }
    });
    debugPrint('[RLINK][BLE] Scanning started');
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
      _updatePeersCount();
      // Помечаем как ожидающий профиль
      final newPending = Set<String>.from(pendingProfiles.value)
        ..add(device.remoteId.str);
      pendingProfiles.value = newPending;
      debugPrint('[RLINK][BLE] Connected to ${device.remoteId}');
      setExchangeState(device.remoteId.str, 0); // connected
      // Уведомляем о новом подключении (без авто-обмена профилями)
      onPeerConnected?.call(device.remoteId.str);
    } catch (e) {
      debugPrint('[RLINK][BLE] Connect failed: $e');
      _connectedPeers.remove(device.remoteId);
      _updatePeersCount();
    } finally {
      _connecting.remove(device.remoteId);
    }

    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        final bleId = device.remoteId.str;
        // Убираем pending при отключении
        final newPending = Set<String>.from(pendingProfiles.value)
          ..remove(bleId);
        pendingProfiles.value = newPending;
        // НЕ удаляем publicKey маппинг — чтобы chat знал что пир был известен
        // Маппинг обновится при следующем обмене профилями
        _connectedPeers.remove(device.remoteId);
        _txChars.remove(device.remoteId);
        _updatePeersCount();
        debugPrint('[RLINK][BLE] Disconnected: $bleId');
        // Пробуем переподключиться через 1 секунду
        if (_isRunning) {
          Future.delayed(const Duration(seconds: 1), () {
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
        final frameBuf = _FrameBuffer();
        char.lastValueStream.listen((bytes) {
          if (bytes.isNotEmpty) {
            for (final packet in frameBuf.feed(bytes)) {
              GossipRouter.instance.onPacketReceived(packet, sourceId: bleId);
            }
          }
        });
        _txChars[device.remoteId] = char;
        debugPrint('[RLINK][BLE] GATT ready for $bleId');
      }
    }
  }

  Future<void> _writeChar(BluetoothCharacteristic char, Uint8List bytes) async {
    // Prepend 2-byte big-endian length header for framing, then send in 180-byte chunks.
    // Use write-with-response so that the peripheral's didReceiveWrite callback fires.
    const chunkSize = 180;
    final framed = Uint8List(2 + bytes.length);
    framed[0] = (bytes.length >> 8) & 0xFF;
    framed[1] = bytes.length & 0xFF;
    framed.setRange(2, framed.length, bytes);

    for (int offset = 0; offset < framed.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, framed.length);
      final chunk = framed.sublist(offset, end);
      try {
        await char
            .write(chunk, withoutResponse: false)
            .timeout(const Duration(seconds: 5));
        // Small delay between chunks to let BLE stack breathe
        if (end < framed.length) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      } catch (e) {
        debugPrint('[RLINK][BLE] Write failed at offset=$offset/${framed.length}: $e');
        return; // Abort this write — retry at gossip level will resend
      }
    }
  }

  Future<void> _requestPermissions() async {
    if (_isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location,
        Permission.camera,
        Permission.microphone,
        Permission.photos,
      ].request();
    } else if (_isIOS) {
      await [
        Permission.bluetooth,
        Permission.camera,
        Permission.microphone,
        Permission.location,
        Permission.photos,
      ].request();
    } else if (_isMacOS) {
      await [
        Permission.bluetooth,
        Permission.camera,
        Permission.microphone,
        Permission.location,
      ].request();
    }
    // Windows/Linux: no BLE permission API needed
  }

  Future<void> _waitForAdapter() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return;
    await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(const Duration(seconds: 30));
  }
}

/// Reassembles length-prefixed BLE frames split across multiple notifications/writes.
/// Protocol: each message is prefixed with a 2-byte big-endian length, then payload bytes.
class _FrameBuffer {
  final List<int> _buf = [];
  DateTime _lastActivity = DateTime.now();
  static const _kMaxBufSize = 4000; // max sane buffer size
  static const _kStaleTimeout = Duration(seconds: 5);

  List<Uint8List> feed(List<int> bytes) {
    final now = DateTime.now();
    // If buffer has stale partial data, clear it before adding new bytes
    if (_buf.isNotEmpty && now.difference(_lastActivity) > _kStaleTimeout) {
      debugPrint('[FrameBuffer] Clearing stale buffer (${_buf.length} bytes, ${now.difference(_lastActivity).inSeconds}s old)');
      _buf.clear();
    }
    _lastActivity = now;
    _buf.addAll(bytes);

    // Prevent unbounded buffer growth from corrupted streams
    if (_buf.length > _kMaxBufSize) {
      debugPrint('[FrameBuffer] Buffer overflow (${_buf.length} bytes), clearing');
      _buf.clear();
      return [];
    }

    final packets = <Uint8List>[];
    while (_buf.length >= 2) {
      final len = (_buf[0] << 8) | _buf[1];
      if (len == 0 || len > 2000) {
        // Corrupt or oversized header — discard buffer
        debugPrint('[FrameBuffer] Invalid frame length=$len, clearing buffer');
        _buf.clear();
        break;
      }
      if (_buf.length < len + 2) break;
      packets.add(Uint8List.fromList(_buf.sublist(2, len + 2)));
      _buf.removeRange(0, len + 2);
    }
    return packets;
  }
}
