package xyz.depollsoft.monkeyssh

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

class MonkeySshApplication : Application() {

    companion object {
        const val SHARED_ENGINE_ID = "monkeyssh_shared_engine"

        fun from(context: Context): MonkeySshApplication =
            context.applicationContext as MonkeySshApplication
    }

    @Volatile
    private var sharedFlutterEngine: FlutterEngine? = null

    @Synchronized
    fun ensureSharedFlutterEngine(): FlutterEngine {
        sharedFlutterEngine?.let { return it }

        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine)
        SshServiceChannelHandler.attachToEngine(engine, applicationContext)
        DeviceDebugChannelHandler.attachToEngine(engine, applicationContext)
        SocksBrowserProxyChannelHandler.attachToEngine(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(SHARED_ENGINE_ID, engine)
        sharedFlutterEngine = engine
        return engine
    }
}
