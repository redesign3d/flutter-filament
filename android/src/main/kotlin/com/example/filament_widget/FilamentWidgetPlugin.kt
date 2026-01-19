package com.example.filament_widget

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class FilamentWidgetPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    private lateinit var flutterAssets: FlutterPlugin.FlutterAssets
    private val renderThread = FilamentRenderThread()
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val controllers = ConcurrentHashMap<Int, FilamentControllerState>()
    private val eventSinks = ConcurrentHashMap<Int, EventChannel.EventSink>()
    private var cacheManager: FilamentCacheManager? = null
    private var activity: Activity? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        flutterAssets = binding.flutterAssets
        textureRegistry = binding.textureRegistry
        cacheManager = FilamentCacheManager(context.cacheDir)
        methodChannel = MethodChannel(binding.binaryMessenger, "filament_widget")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "filament_widget/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        for ((_, controller) in controllers) {
            controller.dispose(ResultStub())
        }
        controllers.clear()
        ioExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "createController" -> handleCreateController(call, result)
            "disposeController" -> handleDisposeController(call, result)
            "createViewer" -> handleCreateViewer(call, result)
            "resize" -> handleResize(call, result)
            "clearScene" -> handleClearScene(call, result)
            "loadModelFromAsset" -> handleLoadModelFromAsset(call, result)
            "loadModelFromUrl" -> handleLoadModelFromUrl(call, result)
            "getCacheSizeBytes" -> handleCacheSize(call, result)
            "clearCache" -> handleClearCache(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val controllerId = (arguments as? Map<*, *>)?.get("controllerId") as? Number
        if (controllerId == null) {
            events.error("filament_error", "Missing controllerId for events.", null)
            return
        }
        eventSinks[controllerId.toInt()] = events
    }

    override fun onCancel(arguments: Any?) {
        val controllerId = (arguments as? Map<*, *>)?.get("controllerId") as? Number
        if (controllerId != null) {
            eventSinks.remove(controllerId.toInt())
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        val app = binding.activity.application
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                if (activity == this@FilamentWidgetPlugin.activity) {
                    renderThread.setPaused(false)
                }
            }

            override fun onActivityPaused(activity: Activity) {
                if (activity == this@FilamentWidgetPlugin.activity) {
                    renderThread.setPaused(true)
                }
            }

            override fun onActivityCreated(activity: Activity, state: android.os.Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: android.os.Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        lifecycleCallbacks = callbacks
        app.registerActivityLifecycleCallbacks(callbacks)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        lifecycleCallbacks?.let { activity?.application?.unregisterActivityLifecycleCallbacks(it) }
        lifecycleCallbacks = null
        activity = null
        renderThread.setPaused(true)
    }

    private fun handleCreateController(call: MethodCall, result: Result) {
        val controllerId = call.argument<Number>("controllerId")?.toInt()
        if (controllerId == null) {
            result.error("filament_error", "Missing controllerId.", null)
            return
        }
        val cache = cacheManager ?: FilamentCacheManager(context.cacheDir)
        cacheManager = cache
        val controller = FilamentControllerState(
            controllerId,
            context,
            flutterAssets,
            textureRegistry,
            renderThread,
            ioExecutor,
            mainHandler,
            cache,
        ) { type, message ->
            emitEvent(controllerId, type, message)
        }
        controllers[controllerId] = controller
        result.success(null)
    }

    private fun handleDisposeController(call: MethodCall, result: Result) {
        val controllerId = call.argument<Number>("controllerId")?.toInt()
        if (controllerId == null) {
            result.error("filament_error", "Missing controllerId.", null)
            return
        }
        val controller = controllers.remove(controllerId)
        if (controller == null) {
            result.success(null)
            return
        }
        controller.dispose(result)
    }

    private fun handleCreateViewer(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val width = call.argument<Number>("width")?.toInt() ?: 1
        val height = call.argument<Number>("height")?.toInt() ?: 1
        controller.createViewer(width, height, result)
    }

    private fun handleResize(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val width = call.argument<Number>("width")?.toInt() ?: 1
        val height = call.argument<Number>("height")?.toInt() ?: 1
        controller.resize(width, height, result)
    }

    private fun handleClearScene(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.clearScene(result)
    }

    private fun handleLoadModelFromAsset(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val assetPath = call.argument<String>("assetPath")
        if (assetPath.isNullOrBlank()) {
            result.error("filament_error", "Missing assetPath.", null)
            return
        }
        controller.loadModelFromAsset(assetPath, result)
    }

    private fun handleLoadModelFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("filament_error", "Missing url.", null)
            return
        }
        controller.loadModelFromUrl(url, result)
    }

    private fun handleCacheSize(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.getCacheSizeBytes(result)
    }

    private fun handleClearCache(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.clearCache(result)
    }

    private fun resolveController(call: MethodCall, result: Result): FilamentControllerState? {
        val controllerId = call.argument<Number>("controllerId")?.toInt()
        if (controllerId == null) {
            result.error("filament_error", "Missing controllerId.", null)
            return null
        }
        val controller = controllers[controllerId]
        if (controller == null) {
            result.error("filament_error", "Unknown controllerId.", null)
        }
        return controller
    }

    private fun emitEvent(controllerId: Int, type: String, message: String) {
        mainHandler.post {
            eventSinks[controllerId]?.success(
                mapOf(
                    "type" to type,
                    "message" to message,
                ),
            )
        }
    }

    private class ResultStub : Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }
}
