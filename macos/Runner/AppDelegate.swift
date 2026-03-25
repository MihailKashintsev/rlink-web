import Cocoa
import FlutterMacOS
import CoreBluetooth

@main
class AppDelegate: FlutterAppDelegate {

    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    private let txCharUUID  = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")

    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var eventSink: FlutterEventSink?
    private var subscribedCentrals: [CBCentral] = []
    private var pendingEvents: [[String: Any]] = []
    private var dataChannel: FlutterMethodChannel?
    private let maxBufferSize = 50
    // Per-central reassembly buffers for incoming writes
    private var writeBuffers: [UUID: Data] = [:]

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        DispatchQueue.main.async { self.setupChannels() }
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Channel Setup

    private func setupChannels() {
        var flutterVC: FlutterViewController?
        for window in NSApp.windows {
            if let vc = window.contentViewController as? FlutterViewController {
                flutterVC = vc
                break
            }
        }
        guard let vc = flutterVC else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.setupChannels() }
            return
        }

        NSLog("[AppDelegate macOS] setupChannels OK")
        let m = vc.engine.binaryMessenger

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
                self.flushPendingEvents()
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }

        dataChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble_data", binaryMessenger: m)
        NSLog("[AppDelegate macOS] dataChannel created")

        FlutterEventChannel(name: "com.rendergames.rlink/ble_events", binaryMessenger: m)
            .setStreamHandler(self)

        if !pendingEvents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.flushPendingEvents()
            }
        }
    }

    // MARK: - Buffer

    private func bufferEvent(deviceId: String, data: Data) {
        if pendingEvents.count >= maxBufferSize { pendingEvents.removeFirst() }
        pendingEvents.append(["device": deviceId, "data": data])
    }

    private func trySendOrBuffer(deviceId: String, data: Data) {
        DispatchQueue.main.async {
            if let sink = self.eventSink {
                sink(["type": "data", "device": deviceId,
                      "data": FlutterStandardTypedData(bytes: data)])
                return
            }
            if let ch = self.dataChannel {
                ch.invokeMethod("onBleData", arguments: [
                    "device": deviceId,
                    "data": FlutterStandardTypedData(bytes: data)
                ])
                return
            }
            self.bufferEvent(deviceId: deviceId, data: data)
        }
    }

    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        guard eventSink != nil || dataChannel != nil else { return }
        let toFlush = pendingEvents
        pendingEvents.removeAll()
        for item in toFlush {
            if let dev = item["device"] as? String, let dat = item["data"] as? Data {
                trySendOrBuffer(deviceId: dev, data: dat)
            }
        }
    }

    // MARK: - BLE Peripheral

    private func startAdvertisingAndService() {
        NSLog("[AppDelegate macOS] startAdvertisingAndService")
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
        guard let char = txCharacteristic, let pm = peripheralManager else { return }
        // Prepend 2-byte big-endian length header, then send in per-central MTU-sized chunks.
        var framed = Data()
        let length = data.count
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(contentsOf: data)
        for central in subscribedCentrals {
            let mtu = max(20, central.maximumUpdateValueLength)
            var offset = 0
            while offset < framed.count {
                let end = min(offset + mtu, framed.count)
                let chunk = framed.subdata(in: offset..<end)
                if !pm.updateValue(chunk, for: char, onSubscribedCentrals: [central]) {
                    NSLog("[AppDelegate macOS] updateValue false at offset %d/%d", offset, framed.count)
                    break
                }
                offset = end
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension AppDelegate: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        NSLog("[AppDelegate macOS] BT state=%d", peripheral.state.rawValue)
        if peripheral.state == .poweredOn { startAdvertisingAndService() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        NSLog("[AppDelegate macOS] didAdd error=%@", error?.localizedDescription ?? "nil")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        NSLog("[AppDelegate macOS] advertising error=%@", error?.localizedDescription ?? "nil")
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
                let centralId = req.central.identifier
                var buf = writeBuffers[centralId] ?? Data()
                buf.append(contentsOf: data)
                while buf.count >= 2 {
                    let length = Int(buf[0]) << 8 | Int(buf[1])
                    if length == 0 || length > 60000 {
                        NSLog("[AppDelegate macOS] corrupt frame length=%d, clearing buffer", length)
                        buf = Data()
                        break
                    }
                    if buf.count < length + 2 { break }
                    let packet = buf.subdata(in: 2..<(length + 2))
                    buf = buf.count > length + 2 ? Data(buf[(length + 2)...]) : Data()
                    trySendOrBuffer(deviceId: centralId.uuidString, data: packet)
                }
                writeBuffers[centralId] = buf
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        NSLog("[AppDelegate macOS] subscribed: %@", central.identifier.uuidString)
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        writeBuffers.removeValue(forKey: central.identifier)
    }
}

// MARK: - FlutterStreamHandler

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        NSLog("[AppDelegate macOS] onListen")
        self.eventSink = events
        if !pendingEvents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.flushPendingEvents() }
        }
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
