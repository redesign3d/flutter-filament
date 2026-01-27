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
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class FilamentWidgetPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var controlChannel: BasicMessageChannel<ByteBuffer>
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    private lateinit var flutterAssets: FlutterPlugin.FlutterAssets
    private var renderThread: FilamentRenderThread? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val controllers = ConcurrentHashMap<Int, FilamentControllerState>()
    private val nextControllerId = AtomicLong(1)
    private var eventSink: EventChannel.EventSink? = null
    private var cacheManager: FilamentCacheManager? = null
    private var activity: Activity? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null
    private val hdriLightingSizes = setOf(64, 128, 256, 512, 1024, 2048)
    private val hdriSkyboxSizes = setOf(512, 1024, 2048, 4096, 8192)

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        flutterAssets = binding.flutterAssets
        textureRegistry = binding.textureRegistry
        cacheManager = FilamentCacheManager(context.cacheDir)
        renderThread = FilamentRenderThread()
        methodChannel = MethodChannel(binding.binaryMessenger, "filament_widget")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "filament_widget/events")
        eventChannel.setStreamHandler(this)
        controlChannel = BasicMessageChannel(binding.binaryMessenger, "filament_widget/controls", BinaryCodec.INSTANCE)
        controlChannel.setMessageHandler { message, reply ->
            handleControlMessage(message)
            reply.reply(null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        controlChannel.setMessageHandler(null)
        renderThread?.setAppPaused(true)
        for ((_, controller) in controllers) {
            controller.dispose(ResultStub())
        }
        controllers.clear()
        ioExecutor.shutdown()
        renderThread?.dispose()
        renderThread = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val safeResult = MethodResultOnce(result, mainHandler)
        when (call.method) {
            "createController" -> handleCreateController(call, safeResult)
            "disposeController" -> handleDisposeController(call, safeResult)
            "createViewer" -> handleCreateViewer(call, safeResult)
            "resize" -> handleResize(call, safeResult)
            "clearScene" -> handleClearScene(call, safeResult)
            "loadModelFromAsset" -> handleLoadModelFromAsset(call, safeResult)
            "loadModelFromUrl" -> handleLoadModelFromUrl(call, safeResult)
            "loadModelFromFile" -> handleLoadModelFromFile(call, safeResult)
            "getCacheSizeBytes" -> handleCacheSize(call, safeResult)
            "clearCache" -> handleClearCache(call, safeResult)
            "setIBLFromAsset" -> handleSetIBLFromAsset(call, safeResult)
            "setSkyboxFromAsset" -> handleSetSkyboxFromAsset(call, safeResult)
            "setHdriFromAsset" -> handleSetHdriFromAsset(call, safeResult)
            "setIBLFromUrl" -> handleSetIBLFromUrl(call, safeResult)
            "setSkyboxFromUrl" -> handleSetSkyboxFromUrl(call, safeResult)
            "setHdriFromUrl" -> handleSetHdriFromUrl(call, safeResult)
            "frameModel" -> handleFrameModel(call, safeResult)
            "setOrbitConstraints" -> handleOrbitConstraints(call, safeResult)
            "setInertiaEnabled" -> handleInertiaEnabled(call, safeResult)
            "setInertiaParams" -> handleInertiaParams(call, safeResult)
            "setZoomLimits" -> handleZoomLimits(call, safeResult)
            "setCustomCameraEnabled" -> handleCustomCameraEnabled(call, safeResult)
            "setCustomCameraLookAt" -> handleCustomCameraLookAt(call, safeResult)
            "setCustomPerspective" -> handleCustomPerspective(call, safeResult)
            "getAnimationCount" -> handleGetAnimationCount(call, safeResult)
            "playAnimation" -> handlePlayAnimation(call, safeResult)
            "pauseAnimation" -> handlePauseAnimation(call, safeResult)
            "seekAnimation" -> handleSeekAnimation(call, safeResult)
            "setAnimationSpeed" -> handleSetAnimationSpeed(call, safeResult)
            "getAnimationDuration" -> handleGetAnimationDuration(call, safeResult)
            "setMsaa" -> handleSetMsaa(call, safeResult)
            "setDynamicResolutionEnabled" -> handleSetDynamicResolutionEnabled(call, safeResult)
            "setToneMappingFilmic" -> handleSetToneMappingFilmic(call, safeResult)
            "setEnvironmentEnabled" -> handleSetEnvironmentEnabled(call, safeResult)
            "setShadowsEnabled" -> handleSetShadowsEnabled(call, safeResult)
            "setWireframeEnabled" -> handleSetWireframeEnabled(call, safeResult)
            "setBoundingBoxesEnabled" -> handleSetBoundingBoxesEnabled(call, safeResult)
            "setDebugLoggingEnabled" -> handleSetDebugLoggingEnabled(call, safeResult)
            "orbitStart" -> handleOrbitStart(call, safeResult)
            "orbitDelta" -> handleOrbitDelta(call, safeResult)
            "orbitEnd" -> handleOrbitEnd(call, safeResult)
            "zoomStart" -> handleZoomStart(call, safeResult)
            "zoomDelta" -> handleZoomDelta(call, safeResult)
            "zoomEnd" -> handleZoomEnd(call, safeResult)
            else -> safeResult.notImplemented()
        }
    }

    private fun parseHdriSizes(call: MethodCall, result: Result): Pair<Int, Int>? {
        val lightingSize = call.argument<Int>("lightingCubemapSize") ?: 256
        val skyboxSize = call.argument<Int>("skyboxCubemapSize") ?: lightingSize
        if (!hdriLightingSizes.contains(lightingSize)) {
            result.error(
                FilamentErrors.INVALID_ARGS,
                "lightingCubemapSize must be one of ${hdriLightingSizes.sorted()}.",
                null
            )
            return null
        }
        if (!hdriSkyboxSizes.contains(skyboxSize)) {
            result.error(
                FilamentErrors.INVALID_ARGS,
                "skyboxCubemapSize must be one of ${hdriSkyboxSizes.sorted()}.",
                null
            )
            return null
        }
        if (skyboxSize < lightingSize) {
            result.error(
                FilamentErrors.INVALID_ARGS,
                "skyboxCubemapSize must be >= lightingCubemapSize.",
                null
            )
            return null
        }
        return lightingSize to skyboxSize
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun handleControlMessage(message: ByteBuffer?) {
        if (message == null) return
        message.order(ByteOrder.LITTLE_ENDIAN)
        if (message.remaining() < 24) return

        val controllerId = message.getInt()
        val opcode = message.getInt()
        val a = message.getFloat()
        val b = message.getFloat()
        val c = message.getFloat()
        val flags = message.getInt()

        val controller = controllers[controllerId] ?: return

        when (flags) {
            1 -> controller.setGestureActive(true) // START
            2 -> controller.setGestureActive(false) // END
        }

        when (opcode) {
            1 -> { // ORBIT
                controller.orbitDeltaNoResult(a.toDouble(), b.toDouble())
            }
            2 -> { // ZOOM
                controller.zoomDeltaNoResult(c.toDouble())
            }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        val app = binding.activity.application
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                if (activity == this@FilamentWidgetPlugin.activity) {
                    renderThread?.setAppPaused(false)
                }
            }

            override fun onActivityPaused(activity: Activity) {
                if (activity == this@FilamentWidgetPlugin.activity) {
                    renderThread?.setAppPaused(true)
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
        renderThread?.setPaused(true)
    }

    private fun handleCreateController(call: MethodCall, result: Result) {
        val debugFeaturesEnabled = call.argument<Boolean>("debugFeaturesEnabled") ?: true
        val controllerId = generateControllerId(result) ?: return
        val rThread = renderThread
        if (rThread == null) {
            result.error(FilamentErrors.NATIVE, "Render thread not initialized.", null)
            return
        }
        val cache = cacheManager ?: FilamentCacheManager(context.cacheDir)
        cacheManager = cache
        val controller = FilamentControllerState(
            controllerId,
            context,
            flutterAssets,
            textureRegistry,
            rThread,
            ioExecutor,
            mainHandler,
            cache,
            { type, message ->
                emitEvent(controllerId, type, message)
            },
            debugFeaturesEnabled
        )
        controllers[controllerId] = controller
        result.success(controllerId)
    }

    private fun generateControllerId(result: Result): Int? {
        repeat(10) {
            val candidate = nextControllerId.getAndIncrement()
            if (candidate > Int.MAX_VALUE) {
                result.error(FilamentErrors.NATIVE, "Controller id overflow.", null)
                return null
            }
            val id = candidate.toInt()
            if (!controllers.containsKey(id)) {
                return id
            }
        }
        result.error(FilamentErrors.NATIVE, "Failed to allocate controller id.", null)
        return null
    }

    private fun handleDisposeController(call: MethodCall, result: Result) {
        val controllerId = call.argument<Number>("controllerId")?.toInt()
        if (controllerId == null) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing controllerId.", null)
            return
        }
        val controller = controllers.remove(controllerId)
        if (controller == null) {
            result.error(FilamentErrors.DISPOSED, "Controller already disposed.", null)
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
            result.error(FilamentErrors.INVALID_ARGS, "Missing assetPath.", null)
            return
        }
        controller.loadModelFromAsset(assetPath, result)
    }

    private fun handleLoadModelFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing url.", null)
            return
        }
        controller.loadModelFromUrl(url, result)
    }

    private fun handleLoadModelFromFile(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing filePath.", null)
            return
        }
        controller.loadModelFromFile(filePath, result)
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
            result.error(FilamentErrors.INVALID_ARGS, "Missing ktxPath.", null)
            return
        }
        controller.setIBLFromAsset(assetPath, result)
    }

    private fun handleSetSkyboxFromAsset(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val assetPath = call.argument<String>("ktxPath")
        if (assetPath.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing ktxPath.", null)
            return
        }
        controller.setSkyboxFromAsset(assetPath, result)
    }

    private fun handleSetHdriFromAsset(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val assetPath = call.argument<String>("hdrPath")
        if (assetPath.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing hdrPath.", null)
            return
        }
        val sizes = parseHdriSizes(call, result) ?: return
        controller.setHdriFromAsset(assetPath, sizes.first, sizes.second, result)
    }

    private fun handleSetIBLFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing url.", null)
            return
        }
        controller.setIBLFromUrl(url, result)
    }

    private fun handleSetSkyboxFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing url.", null)
            return
        }
        controller.setSkyboxFromUrl(url, result)
    }

    private fun handleSetHdriFromUrl(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error(FilamentErrors.INVALID_ARGS, "Missing url.", null)
            return
        }
        val sizes = parseHdriSizes(call, result) ?: return
        controller.setHdriFromUrl(url, sizes.first, sizes.second, result)
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

    private fun handleSetEnvironmentEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: true
        controller.setEnvironmentEnabled(enabled, result)
    }

    private fun handleSetShadowsEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: true
        controller.setShadowsEnabled(enabled, result)
    }

    private fun handleSetWireframeEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: false
        controller.setWireframeEnabled(enabled, result)
    }

    private fun handleSetBoundingBoxesEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: false
        controller.setBoundingBoxesEnabled(enabled, result)
    }

    private fun handleSetDebugLoggingEnabled(call: MethodCall, result: Result) {
        val controller = resolveController(call, result) ?: return
        val enabled = call.argument<Boolean>("enabled") ?: false
        controller.setDebugLoggingEnabled(enabled, result)
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
            result.error(FilamentErrors.INVALID_ARGS, "Missing controllerId.", null)
            return null
        }
        val controller = controllers[controllerId]
        if (controller == null) {
            result.error(FilamentErrors.DISPOSED, "Controller disposed.", null)
        }
        return controller
    }

    private fun emitEvent(controllerId: Int, type: String, message: String) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "controllerId" to controllerId,
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
