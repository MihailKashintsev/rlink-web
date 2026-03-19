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
    private var pendingEvents: [Any] = []
    private var dataChannel: FlutterMethodChannel?

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

    private func sendToFlutter(deviceId: String, data: Data) {
        DispatchQueue.main.async {
            if let sink = self.eventSink {
                sink(["type": "data", "device": deviceId,
                      "data": FlutterStandardTypedData(bytes: data)])
            } else if let ch = self.dataChannel {
                ch.invokeMethod("onBleData", arguments: [
                    "device": deviceId,
                    "data": FlutterStandardTypedData(bytes: data)
                ])
            } else {
                self.pendingEvents.append(["device": deviceId, "data": data])
            }
        }
    }

    private func flushPendingEvents() {
        let toFlush = pendingEvents; pendingEvents.removeAll()
        for item in toFlush {
            if let d = item as? [String: Any],
               let dev = d["device"] as? String,
               let dat = d["data"] as? Data {
                sendToFlutter(deviceId: dev, data: dat)
            }
        }
    }

    private func setupChannels() {
        guard let vc = window?.rootViewController as? FlutterViewController else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.setupChannels() }
            return
        }
        let m = vc.binaryMessenger

        let method = FlutterMethodChannel(name: "com.rendergames.rlink/ble", binaryMessenger: m)
        method.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "startAdvertising": result(nil)
            case "stopAdvertising": self?.peripheralManager?.stopAdvertising(); result(nil)
            case "sendPacket":
                if let a = call.arguments as? [String: Any],
                   let d = a["data"] as? FlutterStandardTypedData {
                    self?.notifySubscribers(data: d.data)
                }
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }

        dataChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble_data", binaryMessenger: m)
        FlutterEventChannel(name: "com.rendergames.rlink/ble_events", binaryMessenger: m)
            .setStreamHandler(self)

        flushPendingEvents()
    }

    private func startAdvertisingAndService() {
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
        if peripheral.state == .poweredOn { startAdvertisingAndService() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {}

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard error == nil else { return }
        DispatchQueue.main.async {
            let event: Any = ["type": "advertising_started"]
            if let sink = self.eventSink { sink(event) }
            else { self.dataChannel?.invokeMethod("onAdvertisingStarted", arguments: nil) }
        }
    }

    // Вызывается для ОБОИХ типов: write with response И write without response
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if req.characteristic.uuid == txCharUUID, let data = req.value {
                let deviceId = req.central.identifier.uuidString
                NSLog("[AppDelegate] write len=%d from=%@", data.count, deviceId)
                sendToFlutter(deviceId: deviceId, data: data)
            }
            // Отвечаем только если запрос требует ответа (write with response)
            // Для writeWithoutResponse respond тоже безопасен
            peripheral.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
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
        self.eventSink = events
        flushPendingEvents()
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}