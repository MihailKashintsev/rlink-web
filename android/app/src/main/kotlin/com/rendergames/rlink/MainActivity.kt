package com.rendergames.rlink

import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        const val METHOD_CHANNEL = "com.rendergames.rlink/ble"
        const val EVENT_CHANNEL  = "com.rendergames.rlink/ble_events"
        const val NOTIFICATION_CHANNEL_ID = "rlink_messages"
        val SERVICE_UUID: UUID = UUID.fromString("12345678-1234-5678-1234-56789abcdef0")
        val TX_CHAR_UUID: UUID = UUID.fromString("12345678-1234-5678-1234-56789abcdef1")
        val CCCD_UUID:    UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var eventSink: EventChannel.EventSink? = null
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()

    // Per-device write buffers for reassembling framed BLE packets
    // (same protocol as iOS: 2-byte big-endian length header + payload)
    private val writeBuffers = mutableMapOf<String, ByteArray>()

    // Флаг — предотвращаем дублирование
    private var isAdvertising = false
    private var isGattServerRunning = false

    // Отслеживаем foreground/background для уведомлений
    private var isAppInForeground = false

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
    }

    override fun onPause() {
        super.onPause()
        isAppInForeground = false
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Сообщения Rlink",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Уведомления о новых сообщениях"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun showMessageNotification(title: String = "Rlink", body: String = "Новое сообщение", sound: Boolean = true, vibration: Boolean = true) {
        if (isAppInForeground) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Recreate channel with correct sound/vibration settings
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = if (sound) NotificationManager.IMPORTANCE_DEFAULT else NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(NOTIFICATION_CHANNEL_ID, "Сообщения Rlink", importance).apply {
                description = "Уведомления о новых сообщениях"
                enableVibration(vibration)
                if (!sound) setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)

        if (!sound) builder.setSound(null)
        if (!vibration) builder.setVibrate(null)

        manager.notify(System.currentTimeMillis().toInt(), builder.build())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        if (!isGattServerRunning) startGattServer()
                        if (!isAdvertising) startAdvertising()
                        result.success(null)
                    }
                    "stopAdvertising" -> {
                        stopAdvertising()
                        result.success(null)
                    }
                    "sendPacket" -> {
                        val bytes = call.argument<ByteArray>("data")
                        if (bytes != null) notifySubscribers(bytes)
                        result.success(null)
                    }
                    "showNotification" -> {
                        val title = call.argument<String>("title") ?: "Rlink"
                        val body = call.argument<String>("body") ?: "Новое сообщение"
                        val sound = call.argument<Boolean>("sound") ?: true
                        val vibration = call.argument<Boolean>("vibration") ?: true
                        showMessageNotification(title, body, sound, vibration)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
                override fun onCancel(args: Any?) { eventSink = null }
            })

        // Native square video cropping
        VideoCropPlugin.register(flutterEngine.dartExecutor.binaryMessenger)
    }

    private fun startGattServer() {
        // Закрываем старый если есть
        gattServer?.close()
        subscribedDevices.clear()

        val txChar = BluetoothGattCharacteristic(
            TX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or
            BluetoothGattCharacteristic.PROPERTY_WRITE or
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_READ or
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        txChar.addDescriptor(BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        ))
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(txChar)

        gattServer = bluetoothManager?.openGattServer(this, gattServerCallback)
        gattServer?.addService(service)
        isGattServerRunning = true
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device)
                writeBuffers.remove(device.address)
                runOnUiThread {
                    eventSink?.success(mapOf("type" to "central_unsubscribed", "device" to device.address))
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (characteristic.uuid == TX_CHAR_UUID) {
                val deviceId = device.address
                var buf = writeBuffers[deviceId] ?: ByteArray(0)
                buf = buf + value

                // Extract all complete length-prefixed packets from the buffer
                while (buf.size >= 2) {
                    val length = ((buf[0].toInt() and 0xFF) shl 8) or (buf[1].toInt() and 0xFF)
                    if (length == 0 || length > 2000) {
                        // Corrupt frame — clear buffer
                        buf = ByteArray(0)
                        break
                    }
                    if (buf.size < length + 2) break // incomplete packet, wait for more data
                    val packet = buf.copyOfRange(2, length + 2)
                    buf = if (buf.size > length + 2) buf.copyOfRange(length + 2, buf.size) else ByteArray(0)

                    // Send complete reassembled packet to Flutter with device ID.
                    // Notification is handled on the Dart side after gossip dedup —
                    // do NOT call showMessageNotification() here (it would fire
                    // once per BLE packet, causing duplicate notifications).
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "data", "device" to deviceId, "data" to packet))
                    }
                }
                writeBuffers[deviceId] = buf
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.add(device)
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "central_subscribed", "device" to device.address))
                    }
                } else {
                    subscribedDevices.remove(device)
                    writeBuffers.remove(device.address)
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "central_unsubscribed", "device" to device.address))
                    }
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    private fun notifySubscribers(data: ByteArray) {
        val service = gattServer?.getService(SERVICE_UUID) ?: return
        val char    = service.getCharacteristic(TX_CHAR_UUID) ?: return

        // Prepend 2-byte big-endian length header (same protocol as iOS)
        val length = data.size
        val framed = ByteArray(2 + length)
        framed[0] = ((length shr 8) and 0xFF).toByte()
        framed[1] = (length and 0xFF).toByte()
        System.arraycopy(data, 0, framed, 2, length)

        // Send full framed packet in one notification per device.
        // flutter_blue_plus negotiates MTU 512, so packets up to 509 bytes fit.
        // The flutter_blue_plus _writeChar (GATT client) path provides reliable
        // chunked delivery as backup for any packets that exceed the MTU.
        // NOTE: Do NOT chunk in a loop here — setting char.value multiple times
        // before the BLE stack sends previous notifications causes data corruption.
        char.value = framed
        subscribedDevices.toList().forEach { device ->
            try {
                gattServer?.notifyCharacteristicChanged(device, char, false)
            } catch (e: Exception) {
                subscribedDevices.remove(device)
            }
        }
    }

    private fun startAdvertising() {
        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun stopAdvertising() {
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        isAdvertising = false
        isGattServerRunning = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            runOnUiThread { eventSink?.success(mapOf("type" to "advertising_started")) }
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            // Код 3 = уже запущен — не считаем ошибкой
            if (errorCode != 3) {
                runOnUiThread {
                    eventSink?.error("ADV_FAILED", "Advertising failed: $errorCode", null)
                }
            } else {
                isAdvertising = true // уже работает
                runOnUiThread { eventSink?.success(mapOf("type" to "advertising_started")) }
            }
        }
    }
}