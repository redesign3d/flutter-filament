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
            "setIBLFromAsset" -> handleSetIBLFromAsset(call, result)
            "setSkyboxFromAsset" -> handleSetSkyboxFromAsset(call, result)
            "setIBLFromUrl" -> handleSetIBLFromUrl(call, result)
            "setSkyboxFromUrl" -> handleSetSkyboxFromUrl(call, result)
            "frameModel" -> handleFrameModel(call, result)
            "setOrbitConstraints" -> handleOrbitConstraints(call, result)
            "setInertiaEnabled" -> handleInertiaEnabled(call, result)
            "setInertiaParams" -> handleInertiaParams(call, result)
            "setZoomLimits" -> handleZoomLimits(call, result)
            "setCustomCameraEnabled" -> handleCustomCameraEnabled(call, result)
            "setCustomCameraLookAt" -> handleCustomCameraLookAt(call, result)
            "setCustomPerspective" -> handleCustomPerspective(call, result)
            "getAnimationCount" -> handleGetAnimationCount(call, result)
            "playAnimation" -> handlePlayAnimation(call, result)
            "pauseAnimation" -> handlePauseAnimation(call, result)
            "seekAnimation" -> handleSeekAnimation(call, result)
            "setAnimationSpeed" -> handleSetAnimationSpeed(call, result)
            "getAnimationDuration" -> handleGetAnimationDuration(call, result)
            "setMsaa" -> handleSetMsaa(call, result)
            "setDynamicResolutionEnabled" -> handleSetDynamicResolutionEnabled(call, result)
            "setToneMappingFilmic" -> handleSetToneMappingFilmic(call, result)
            "setShadowsEnabled" -> handleSetShadowsEnabled(call, result)
            "orbitStart" -> handleOrbitStart(call, result)
            "orbitDelta" -> handleOrbitDelta(call, result)
            "orbitEnd" -> handleOrbitEnd(call, result)
            "zoomStart" -> handleZoomStart(call, result)
            "zoomDelta" -> handleZoomDelta(call, result)
            "zoomEnd" -> handleZoomEnd(call, result)
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

    private fun handleSetIBLFromAsset(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val assetPath = call.argument<String>("ktxPath")
        if (assetPath.isNullOrBlank()) {
            result.error("filament_error", "Missing ktxPath.", null)
            return
        }
        controller.setIBLFromAsset(assetPath, result)
    }

    private fun handleSetSkyboxFromAsset(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val assetPath = call.argument<String>("ktxPath")
        if (assetPath.isNullOrBlank()) {
            result.error("filament_error", "Missing ktxPath.", null)
            return
        }
        controller.setSkyboxFromAsset(assetPath, result)
    }

    private fun handleSetIBLFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("filament_error", "Missing url.", null)
            return
        }
        controller.setIBLFromUrl(url, result)
    }

    private fun handleSetSkyboxFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("filament_error", "Missing url.", null)
            return
        }
        controller.setSkyboxFromUrl(url, result)
    }

    private fun handleFrameModel(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val useWorldOrigin = call.argument<Boolean>("useWorldOrigin") ?: false
        controller.frameModel(useWorldOrigin, result)
    }

    private fun handleOrbitConstraints(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val minPitch = call.argument<Double>("minPitchDeg") ?: -89.0
        val maxPitch = call.argument<Double>("maxPitchDeg") ?: 89.0
        val minYaw = call.argument<Double>("minYawDeg") ?: -180.0
        val maxYaw = call.argument<Double>("maxYawDeg") ?: 180.0
        controller.setOrbitConstraints(minPitch, maxPitch, minYaw, maxYaw, result)
    }

    private fun handleInertiaEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: true
        controller.setInertiaEnabled(enabled, result)
    }

    private fun handleInertiaParams(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val damping = call.argument<Double>("damping") ?: 0.9
        val sensitivity = call.argument<Double>("sensitivity") ?: 0.15
        controller.setInertiaParams(damping, sensitivity, result)
    }

    private fun handleZoomLimits(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val minDistance = call.argument<Double>("minDistance") ?: 0.05
        val maxDistance = call.argument<Double>("maxDistance") ?: 100.0
        controller.setZoomLimits(minDistance, maxDistance, result)
    }

    private fun handleCustomCameraEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: false
        controller.setCustomCameraEnabled(enabled, result)
    }

    private fun handleCustomCameraLookAt(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val eyeX = call.argument<Double>("eyeX") ?: 0.0
        val eyeY = call.argument<Double>("eyeY") ?: 0.0
        val eyeZ = call.argument<Double>("eyeZ") ?: 3.0
        val centerX = call.argument<Double>("centerX") ?: 0.0
        val centerY = call.argument<Double>("centerY") ?: 0.0
        val centerZ = call.argument<Double>("centerZ") ?: 0.0
        val upX = call.argument<Double>("upX") ?: 0.0
        val upY = call.argument<Double>("upY") ?: 1.0
        val upZ = call.argument<Double>("upZ") ?: 0.0
        controller.setCustomCameraLookAt(
            eyeX,
            eyeY,
            eyeZ,
            centerX,
            centerY,
            centerZ,
            upX,
            upY,
            upZ,
            result,
        )
    }

    private fun handleCustomPerspective(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val fov = call.argument<Double>("fovDegrees") ?: 45.0
        val near = call.argument<Double>("near") ?: 0.05
        val far = call.argument<Double>("far") ?: 100.0
        controller.setCustomPerspective(fov, near, far, result)
    }

    private fun handleGetAnimationCount(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.getAnimationCount(result)
    }

    private fun handlePlayAnimation(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val index = call.argument<Number>("index")?.toInt() ?: 0
        val loop = call.argument<Boolean>("loop") ?: true
        controller.playAnimation(index, loop, result)
    }

    private fun handlePauseAnimation(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.pauseAnimation(result)
    }

    private fun handleSeekAnimation(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val seconds = call.argument<Number>("seconds")?.toDouble() ?: 0.0
        controller.seekAnimation(seconds, result)
    }

    private fun handleSetAnimationSpeed(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val speed = call.argument<Number>("speed")?.toDouble() ?: 1.0
        controller.setAnimationSpeed(speed, result)
    }

    private fun handleGetAnimationDuration(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val index = call.argument<Number>("index")?.toInt() ?: 0
        controller.getAnimationDuration(index, result)
    }

    private fun handleSetMsaa(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val samples = call.argument<Number>("samples")?.toInt() ?: 2
        controller.setMsaa(samples, result)
    }

    private fun handleSetDynamicResolutionEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: true
        controller.setDynamicResolutionEnabled(enabled, result)
    }

    private fun handleSetToneMappingFilmic(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.setToneMappingFilmic(result)
    }

    private fun handleSetShadowsEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: true
        controller.setShadowsEnabled(enabled, result)
    }

    private fun handleOrbitStart(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.orbitStart(result)
    }

    private fun handleOrbitDelta(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val dx = call.argument<Double>("dx") ?: 0.0
        val dy = call.argument<Double>("dy") ?: 0.0
        controller.orbitDelta(dx, dy, result)
    }

    private fun handleOrbitEnd(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val velocityX = call.argument<Double>("velocityX") ?: 0.0
        val velocityY = call.argument<Double>("velocityY") ?: 0.0
        controller.orbitEnd(velocityX, velocityY, result)
    }

    private fun handleZoomStart(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.zoomStart(result)
    }

    private fun handleZoomDelta(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val scaleDelta = call.argument<Double>("scaleDelta") ?: 1.0
        controller.zoomDelta(scaleDelta, result)
    }

    private fun handleZoomEnd(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        controller.zoomEnd(result)
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
