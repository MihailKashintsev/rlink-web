package com.rendergames.rlink

import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Единый кэшированный [FlutterEngine]: Dart-изолят и relay/Ble продолжают работу
 * после снятия задачи из недавних (пока живёт foreground service).
 */
class RlinkApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        if (FlutterEngineCache.getInstance().contains(ENGINE_ID)) return
        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "rlink_cached_engine"
    }
}
