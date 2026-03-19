import UIKit
import Flutter
import CoreBluetooth

@main
@objc class AppDelegate: FlutterAppDelegate {

    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    private let txCharUUID  = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")

    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var eventSink: FlutterEventSink?
    private var subscribedCentrals: [CBCentral] = []
    private var pendingEvents: [[String: Any]] = []
    private var dataChannel: FlutterMethodChannel?
    private var flushTimer: Timer?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        DispatchQueue.main.async { self.setupChannels() }
        return result
    }

    private func bufferEvent(deviceId: String, data: Data) {
        pendingEvents.append(["device": deviceId, "data": data])
        NSLog("[AppDelegate] buffered event, total=%d", pendingEvents.count)
    }

    private func trySendOrBuffer(deviceId: String, data: Data) {
        DispatchQueue.main.async {
            // Попытка 1: через EventChannel
            if let sink = self.eventSink {
                sink(["type": "data", "device": deviceId,
                      "data": FlutterStandardTypedData(bytes: data)])
                return
            }
            // Попытка 2: через MethodChannel push
            if let ch = self.dataChannel {
                ch.invokeMethod("onBleData", arguments: [
                    "device": deviceId,
                    "data": FlutterStandardTypedData(bytes: data)
                ])
                return
            }
            // Буферизируем
            self.bufferEvent(deviceId: deviceId, data: data)
        }
    }

    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        NSLog("[AppDelegate] flushing %d pending events", pendingEvents.count)
        let toFlush = pendingEvents
        pendingEvents.removeAll()
        for item in toFlush {
            if let dev = item["device"] as? String,
               let dat = item["data"] as? Data {
                trySendOrBuffer(deviceId: dev, data: dat)
            }
        }
    }

    // Таймер-ретрай: пока есть буфер — пробуем отправить каждые 500мс
    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.pendingEvents.isEmpty {
                self.flushTimer?.invalidate()
                return
            }
            self.flushPendingEvents()
        }
    }

    private func setupChannels() {
        guard let vc = window?.rootViewController as? FlutterViewController else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.setupChannels() }
            return
        }
        NSLog("[AppDelegate] setupChannels OK")
        let m = vc.binaryMessenger

        let method = FlutterMethodChannel(name: "com.rendergames.rlink/ble", binaryMessenger: m)
        method.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "startAdvertising": result(nil)
            case "stopAdvertising":
                self.peripheralManager?.stopAdvertising()
                result(nil)
            case "sendPacket":
                if let a = call.arguments as? [String: Any],
                   let d = a["data"] as? FlutterStandardTypedData {
                    self.notifySubscribers(data: d.data)
                }
                result(nil)
            case "flushPendingEvents":
                // Flutter готов принимать — сбрасываем буфер
                NSLog("[AppDelegate] flushPendingEvents called from Flutter, pending=%d", self.pendingEvents.count)
                self.flushPendingEvents()
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }

        dataChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble_data", binaryMessenger: m)
        NSLog("[AppDelegate] dataChannel created")

        FlutterEventChannel(name: "com.rendergames.rlink/ble_events", binaryMessenger: m)
            .setStreamHandler(self)

        // Запускаем таймер-ретрай для буферизованных событий
        if !pendingEvents.isEmpty {
            startFlushTimer()
        }
    }

    private func startAdvertisingAndService() {
        NSLog("[AppDelegate] startAdvertisingAndService")
        txCharacteristic = CBMutableCharacteristic(
            type: txCharUUID,
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let svc = CBMutableService(type: serviceUUID, primary: true)
        svc.characteristics = [txCharacteristic!]
        peripheralManager?.removeAllServices()
        peripheralManager?.add(svc)
        peripheralManager?.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "Rlink"
        ])
    }

    private func notifySubscribers(data: Data) {
        guard let char = txCharacteristic else { return }
        peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil)
    }
}

extension AppDelegate: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        NSLog("[AppDelegate] state=%d", peripheral.state.rawValue)
        if peripheral.state == .poweredOn { startAdvertisingAndService() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        NSLog("[AppDelegate] didAdd error=%@", error?.localizedDescription ?? "nil")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        NSLog("[AppDelegate] advertising error=%@", error?.localizedDescription ?? "nil")
        guard error == nil else { return }
        DispatchQueue.main.async {
            let event: Any = ["type": "advertising_started"]
            if let sink = self.eventSink { sink(event) }
            else { self.dataChannel?.invokeMethod("onAdvertisingStarted", arguments: nil) }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if req.characteristic.uuid == txCharUUID, let data = req.value {
                let deviceId = req.central.identifier.uuidString
                NSLog("[AppDelegate] write len=%d from=%@", data.count, deviceId)
                trySendOrBuffer(deviceId: deviceId, data: data)
                // Запускаем таймер на случай если буфер растёт
                if !pendingEvents.isEmpty { startFlushTimer() }
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        NSLog("[AppDelegate] subscribed: %@", central.identifier.uuidString)
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }
}

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        NSLog("[AppDelegate] onListen SET, pending=%d", pendingEvents.count)
        self.eventSink = events
        flushPendingEvents()
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NSLog("[AppDelegate] onCancel")
        self.eventSink = nil
        return nil
    }
}