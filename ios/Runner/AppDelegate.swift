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
    
    // MethodChannel для отправки данных Flutter → native direction reversed
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
            // Пробуем через EventChannel (если подписан)
            if let sink = self.eventSink {
                sink([
                    "type": "data",
                    "device": deviceId,
                    "data": FlutterStandardTypedData(bytes: data)
                ])
                return
            }
            // Пробуем через MethodChannel invokeMethod (push от native к Flutter)
            if let ch = self.dataChannel {
                ch.invokeMethod("onBleData", arguments: [
                    "device": deviceId,
                    "data": FlutterStandardTypedData(bytes: data)
                ])
                NSLog("[AppDelegate] sent via MethodChannel invokeMethod")
                return
            }
            // Буферизируем
            NSLog("[AppDelegate] buffering event, pending=%d", self.pendingEvents.count)
            self.pendingEvents.append(["device": deviceId, "data": data])
        }
    }

    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        NSLog("[AppDelegate] flushing %d pending events", pendingEvents.count)
        let toFlush = pendingEvents
        pendingEvents.removeAll()
        for item in toFlush {
            if let dict = item as? [String: Any],
               let device = dict["device"] as? String,
               let data = dict["data"] as? Data {
                sendToFlutter(deviceId: device, data: data)
            }
        }
    }

    private func setupChannels() {
        guard let controller = window?.rootViewController as? FlutterViewController else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.setupChannels() }
            return
        }
        NSLog("[AppDelegate] setupChannels OK")

        let messenger = controller.binaryMessenger

        // MethodChannel для команд Flutter → native
        let methodChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble", binaryMessenger: messenger)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "startAdvertising":
                result(nil)
            case "stopAdvertising":
                self?.peripheralManager?.stopAdvertising()
                result(nil)
            case "sendPacket":
                if let args = call.arguments as? [String: Any],
                   let data = args["data"] as? FlutterStandardTypedData {
                    self?.notifySubscribers(data: data.data)
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // MethodChannel для push данных native → Flutter
        dataChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble_data", binaryMessenger: messenger)
        NSLog("[AppDelegate] dataChannel created")

        // EventChannel (запасной путь)
        let eventChannel = FlutterEventChannel(name: "com.rendergames.rlink/ble_events", binaryMessenger: messenger)
        eventChannel.setStreamHandler(self)

        // Сбрасываем буфер
        flushPendingEvents()
    }

    private func startAdvertisingAndService() {
        NSLog("[AppDelegate] startAdvertisingAndService")
        txCharacteristic = CBMutableCharacteristic(
            type: txCharUUID,
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [txCharacteristic!]
        peripheralManager?.removeAllServices()
        peripheralManager?.add(service)
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
        NSLog("[AppDelegate] didAdd service error=%@", error?.localizedDescription ?? "nil")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        NSLog("[AppDelegate] advertising error=%@", error?.localizedDescription ?? "nil")
        if error == nil {
            DispatchQueue.main.async {
                if let sink = self.eventSink {
                    sink(["type": "advertising_started"])
                } else {
                    self.dataChannel?.invokeMethod("onAdvertisingStarted", arguments: nil)
                }
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == txCharUUID, let data = request.value {
                let deviceId = request.central.identifier.uuidString
                NSLog("[AppDelegate] didReceiveWrite len=%d from=%@", data.count, deviceId)
                sendToFlutter(deviceId: deviceId, data: data)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        NSLog("[AppDelegate] subscribed: %@", central.identifier.uuidString)
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }
}

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        NSLog("[AppDelegate] onListen — eventSink SET")
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