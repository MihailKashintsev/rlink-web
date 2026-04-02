import UIKit
import Flutter
import CoreBluetooth
import UserNotifications
import ActivityKit

// Shared Live Activity attributes — must be defined in BOTH Runner and Widget targets
struct RlinkActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var connectedPeers: Int
        var lastSender: String
        var lastMessage: String
        var timestamp: Date
        var signalLevel: Int // 0=none, 1=weak, 2=medium, 3=strong
    }
    var sessionId: String
}

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
    // Per-central reassembly buffers for incoming writes
    private var writeBuffers: [UUID: Data] = [:]
    // Queued outgoing notification bytes per central (for peripheralManagerIsReady retry)
    private var pendingNotifyData: [UUID: Data] = [:]

    // Ограничитель буфера — не больше 50 пакетов
    private let maxBufferSize = 50
    // Live Activity (Dynamic Island)
    private var currentActivity: Any? = nil  // Activity<RlinkActivityAttributes>?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        // Запрашиваем разрешение на уведомления
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
        // Register notification categories with actions
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ", title: "Прочитано",
            options: .destructive
        )
        let messageCategory = UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
        // Настраиваем каналы после старта — retry пока не найдём FlutterViewController
        DispatchQueue.main.async { self.setupChannels() }
        return result
    }

    // MARK: - Channel Setup

    private func setupChannels() {
        // Ищем FlutterViewController: сначала через AppDelegate.window,
        // потом через сцены (FlutterSceneDelegate держит окно в сцене, не в AppDelegate)
        var flutterVC: FlutterViewController?

        if let vc = self.window?.rootViewController as? FlutterViewController {
            flutterVC = vc
        }

        if flutterVC == nil {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    for window in windowScene.windows {
                        if let vc = window.rootViewController as? FlutterViewController {
                            flutterVC = vc
                            break
                        }
                    }
                }
                if flutterVC != nil { break }
            }
        }

        guard let vc = flutterVC else {
            // Flutter ещё не готов — ретрай через 100мс
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.setupChannels() }
            return
        }

        NSLog("[AppDelegate] setupChannels OK")
        let m = vc.binaryMessenger

        // Register native video crop channel
        VideoCropPlugin.register(with: m)

        let method = FlutterMethodChannel(name: "com.rendergames.rlink/ble", binaryMessenger: m)
        method.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "startAdvertising": result(nil) // iOS рекламирует сам через CBPeripheralManager
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
                NSLog("[AppDelegate] flushPendingEvents from Flutter, pending=%d", self.pendingEvents.count)
                self.flushPendingEvents()
                result(nil)
            case "startLiveActivity":
                if let a = call.arguments as? [String: Any] {
                    self.startLiveActivity(args: a)
                }
                result(nil)
            case "updateLiveActivity":
                if let a = call.arguments as? [String: Any] {
                    self.updateLiveActivity(args: a)
                }
                result(nil)
            case "stopLiveActivity":
                self.stopLiveActivity()
                result(nil)
            case "showNotification":
                if let a = call.arguments as? [String: Any] {
                    self.showLocalNotification(args: a)
                }
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }

        dataChannel = FlutterMethodChannel(name: "com.rendergames.rlink/ble_data", binaryMessenger: m)
        NSLog("[AppDelegate] dataChannel created")

        FlutterEventChannel(name: "com.rendergames.rlink/ble_events", binaryMessenger: m)
            .setStreamHandler(self)

        // Каналы готовы — сбрасываем накопленный буфер
        if !pendingEvents.isEmpty {
            NSLog("[AppDelegate] setupChannels: flushing %d buffered events", pendingEvents.count)
            // Небольшая задержка чтобы Flutter успел подписаться на EventChannel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.flushPendingEvents()
            }
        }
    }

    // MARK: - Buffer

    private func bufferEvent(deviceId: String, data: Data) {
        // Отбрасываем самый старый пакет если буфер переполнен
        if pendingEvents.count >= maxBufferSize {
            pendingEvents.removeFirst()
        }
        pendingEvents.append(["device": deviceId, "data": data])
        NSLog("[AppDelegate] buffered event, total=%d", pendingEvents.count)
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
            // Каналы не готовы — буферизуем
            self.bufferEvent(deviceId: deviceId, data: data)
        }
    }

    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        // Не пытаемся сбросить если каналы не готовы — это вызывает бесконечный цикл
        guard eventSink != nil || dataChannel != nil else {
            NSLog("[AppDelegate] flush skipped — channels not ready yet")
            return
        }
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

    // Таймер-ретрай: запускается только если есть буфер И каналы уже готовы
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

    // MARK: - Notifications

    /// Returns true for user-facing message types — avoids spam from img_chunk/ack/profile packets.
    private func isTextMessage(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String else { return false }
        return type == "raw" || type == "msg" || type == "ether"
    }

    /// Reads contacts_cache.json written by Flutter — maps publicKeyHex → nickname.
    private func loadContactsCache() -> [String: String] {
        guard let docDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return [:] }
        let url = docDir.appendingPathComponent("contacts_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return json
    }

    private func showMessageNotification(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["p"] as? [String: Any],
              let type = json["t"] as? String
        else {
            let content = UNMutableNotificationContent()
            content.title = "Rlink"
            content.body = "Новое сообщение"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }

        let cache = loadContactsCache()
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = "MESSAGE"

        switch type {
        case "raw":
            let text = payload["text"] as? String ?? ""
            let from = payload["from"] as? String ?? ""
            let senderName = cache[from] ?? String(from.prefix(8))
            content.title = senderName
            content.body = text.count > 80 ? String(text.prefix(80)) + "…" : text
            content.threadIdentifier = from  // group by sender

        case "msg":
            // Encrypted message — can't decrypt natively, show generic
            let from = payload["from"] as? String ?? ""
            let senderName = cache[from] ?? String(from.prefix(8))
            content.title = senderName
            content.body = "Новое сообщение"
            content.threadIdentifier = from

        case "ether":
            let text = payload["text"] as? String ?? ""
            let nick = payload["nick"] as? String
            content.title = nick != nil ? "Эфир — \(nick!)" : "Эфир"
            content.body = text.count > 80 ? String(text.prefix(80)) + "…" : text
            content.threadIdentifier = "ether"

        default:
            content.title = "Rlink"
            content.body = "Новое сообщение"
        }

        // Increment badge
        let current = UIApplication.shared.applicationIconBadgeNumber
        content.badge = NSNumber(value: current + 1)

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

        // Also update Dynamic Island if active
        if #available(iOS 16.2, *), currentActivity != nil {
            let peers = subscribedCentrals.count
            let sender = content.title
            let msg = content.body
            updateLiveActivity(args: [
                "peers": peers,
                "sender": sender,
                "message": msg,
                "signal": 2
            ])
        }
    }

    // MARK: - Live Activity (Dynamic Island)

    private func startLiveActivity(args: [String: Any]) {
        guard #available(iOS 16.2, *) else { return }

        // End all stale activities first to avoid conflicts
        Task {
            for activity in Activity<RlinkActivityAttributes>.activities {
                let finalContent: ActivityContent<RlinkActivityAttributes.ContentState>? = nil
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }

        // Skip if already have an active one
        if currentActivity != nil { return }

        let peers = args["peers"] as? Int ?? 0
        let sender = args["sender"] as? String ?? ""
        let message = args["message"] as? String ?? ""
        let signal = args["signal"] as? Int ?? 0

        let attributes = RlinkActivityAttributes(sessionId: UUID().uuidString)
        let state = RlinkActivityAttributes.ContentState(
            connectedPeers: peers,
            lastSender: sender,
            lastMessage: message,
            timestamp: Date(),
            signalLevel: signal
        )
        let content = ActivityContent(state: state, staleDate: nil)

        // Slight delay to allow stale cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                self?.currentActivity = activity
                NSLog("[LiveActivity] Started id=%@", activity.id)
            } catch {
                NSLog("[LiveActivity] Start failed: %@", error.localizedDescription)
            }
        }
    }

    private func updateLiveActivity(args: [String: Any]) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = currentActivity as? Activity<RlinkActivityAttributes> else { return }

        let peers = args["peers"] as? Int ?? 0
        let sender = args["sender"] as? String ?? ""
        let message = args["message"] as? String ?? ""
        let signal = args["signal"] as? Int ?? 0

        let state = RlinkActivityAttributes.ContentState(
            connectedPeers: peers,
            lastSender: sender,
            lastMessage: message,
            timestamp: Date(),
            signalLevel: signal
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            NSLog("[LiveActivity] Updated peers=%d", peers)
        }
    }

    private func stopLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = currentActivity as? Activity<RlinkActivityAttributes> else { return }
        Task {
            let finalContent: ActivityContent<RlinkActivityAttributes.ContentState>? = nil
            await activity.end(finalContent, dismissalPolicy: .immediate)
            NSLog("[LiveActivity] Stopped")
        }
        currentActivity = nil
    }

    // MARK: - Local Notifications (improved)

    private func showLocalNotification(args: [String: Any]) {
        let title = args["title"] as? String ?? "Rlink"
        let body = args["body"] as? String ?? "Новое сообщение"
        let threadId = args["threadId"] as? String  // group by sender
        let soundName = args["sound"] as? String ?? "default"
        let vibration = args["vibration"] as? Bool ?? true

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "MESSAGE"
        if let tid = threadId {
            content.threadIdentifier = tid  // groups notifications by sender
        }

        if soundName == "none" || !vibration {
            // Silent notification
        } else if soundName == "default" {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        }

        // Badge: increment
        let current = UIApplication.shared.applicationIconBadgeNumber
        content.badge = NSNumber(value: current + 1)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // immediate delivery
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let e = error { NSLog("[Notification] Error: %@", e.localizedDescription) }
        }
    }

    // MARK: - BLE Peripheral

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
        guard let char = txCharacteristic, let pm = peripheralManager else { return }
        // Prepend 2-byte big-endian length header, then send in per-central MTU-sized chunks.
        // updateValue silently truncates data > ATT_MTU-3, so we must chunk manually.
        var framed = Data()
        let length = data.count
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(contentsOf: data)
        for central in subscribedCentrals {
            // If there is already queued data for this central, append and wait for drain
            // so that byte ordering across messages is preserved.
            if pendingNotifyData[central.identifier] != nil {
                pendingNotifyData[central.identifier]!.append(framed)
                continue
            }
            let mtu = max(20, central.maximumUpdateValueLength)
            var offset = 0
            while offset < framed.count {
                let end = min(offset + mtu, framed.count)
                let chunk = framed.subdata(in: offset..<end)
                if !pm.updateValue(chunk, for: char, onSubscribedCentrals: [central]) {
                    // TX buffer full — queue the remaining bytes and wait for peripheralManagerIsReady
                    pendingNotifyData[central.identifier] = framed.subdata(in: offset..<framed.count)
                    NSLog("[AppDelegate] TX buffer full at %d/%d, queued %d bytes for %@",
                          offset, framed.count, framed.count - offset, central.identifier.uuidString)
                    break
                }
                offset = end
            }
        }
    }

    // Called by CoreBluetooth when the TX queue has room again — drain pending chunks.
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let char = txCharacteristic else { return }
        for central in subscribedCentrals {
            guard let pending = pendingNotifyData[central.identifier], !pending.isEmpty else { continue }
            let mtu = max(20, central.maximumUpdateValueLength)
            var offset = 0
            while offset < pending.count {
                let end = min(offset + mtu, pending.count)
                let chunk = pending.subdata(in: offset..<end)
                if !peripheral.updateValue(chunk, for: char, onSubscribedCentrals: [central]) {
                    // Still full — save the remainder and return; will be called again
                    pendingNotifyData[central.identifier] = pending.subdata(in: offset..<pending.count)
                    return
                }
                offset = end
            }
            pendingNotifyData.removeValue(forKey: central.identifier)
        }
    }

    // FlutterAppDelegate уже наследует UNUserNotificationCenterDelegate
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // В активном режиме Flutter сам покажет — не дублируем
        completionHandler([])
    }
}

// MARK: - CBPeripheralManagerDelegate

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
                let centralId = req.central.identifier
                var buf = writeBuffers[centralId] ?? Data()
                buf.append(contentsOf: data)
                NSLog("[AppDelegate] write chunk len=%d buf=%d from=%@", data.count, buf.count, centralId.uuidString)
                // Extract all complete length-prefixed packets from the buffer
                while buf.count >= 2 {
                    let length = Int(buf[0]) << 8 | Int(buf[1])
                    if length == 0 || length > 2000 {
                        NSLog("[AppDelegate] corrupt frame length=%d, clearing buffer", length)
                        buf = Data()
                        break
                    }
                    if buf.count < length + 2 { break }
                    let packet = buf.subdata(in: 2..<(length + 2))
                    buf = buf.count > length + 2 ? Data(buf[(length + 2)...]) : Data()
                    let deviceId = centralId.uuidString
                    trySendOrBuffer(deviceId: deviceId, data: packet)
                    if !pendingEvents.isEmpty && (eventSink != nil || dataChannel != nil) {
                        startFlushTimer()
                    }
                    let packetCopy = packet
                    DispatchQueue.main.async {
                        if UIApplication.shared.applicationState != .active &&
                           self.isTextMessage(data: packetCopy) {
                            self.showMessageNotification(data: packetCopy)
                        }
                    }
                }
                writeBuffers[centralId] = buf
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
        // Notify Flutter so it can send our profile back to this newly connected central
        let centralId = central.identifier.uuidString
        DispatchQueue.main.async {
            let event: Any = ["type": "central_subscribed", "device": centralId]
            if let sink = self.eventSink { sink(event) }
            else { self.dataChannel?.invokeMethod("onCentralSubscribed", arguments: centralId) }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        writeBuffers.removeValue(forKey: central.identifier)
        pendingNotifyData.removeValue(forKey: central.identifier)
        let centralId = central.identifier.uuidString
        DispatchQueue.main.async {
            let event: Any = ["type": "central_unsubscribed", "device": centralId]
            if let sink = self.eventSink { sink(event) }
            else { self.dataChannel?.invokeMethod("onCentralUnsubscribed", arguments: centralId) }
        }
    }
}

// MARK: - FlutterStreamHandler

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        NSLog("[AppDelegate] onListen SET, pending=%d", pendingEvents.count)
        self.eventSink = events
        // EventChannel готов — сбрасываем буфер
        if !pendingEvents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.flushPendingEvents()
            }
        }
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NSLog("[AppDelegate] onCancel")
        self.eventSink = nil
        return nil
    }
}
