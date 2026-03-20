import UIKit
import Flutter
import CoreBluetooth
import UserNotifications

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

    // Ограничитель буфера — не больше 50 пакетов
    private let maxBufferSize = 50

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

    private func showMessageNotification(from deviceId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Rlink"
        content.body = "Новое сообщение"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
        guard let char = txCharacteristic else { return }
        peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil)
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
                let deviceId = req.central.identifier.uuidString
                NSLog("[AppDelegate] write len=%d from=%@", data.count, deviceId)
                trySendOrBuffer(deviceId: deviceId, data: data)
                // Запускаем таймер только если каналы уже готовы
                if !pendingEvents.isEmpty && (eventSink != nil || dataChannel != nil) {
                    startFlushTimer()
                }
                // Уведомление в фоне
                DispatchQueue.main.async {
                    if UIApplication.shared.applicationState != .active {
                        self.showMessageNotification(from: deviceId)
                    }
                }
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
