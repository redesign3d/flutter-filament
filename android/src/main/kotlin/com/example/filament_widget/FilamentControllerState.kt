package com.example.filament_widget

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterAssets
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService

class FilamentControllerState(
    private val controllerId: Int,
    private val context: Context,
    private val flutterAssets: FlutterAssets,
    private val textureRegistry: TextureRegistry,
    private val renderThread: FilamentRenderThread,
    private val ioExecutor: ExecutorService,
    private val mainHandler: Handler,
    private val cacheManager: FilamentCacheManager,
    private val eventEmitter: (String, String) -> Unit,
) {
    @Volatile
    private var viewer: FilamentViewer? = null

    fun createViewer(width: Int, height: Int, result: Result) {
        if (viewer != null) {
            disposeViewer()
        }
        val entry = textureRegistry.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(width, height)
        val surface = Surface(entry.surfaceTexture())
        val newViewer = FilamentViewer(entry, surface, context.assets, eventEmitter)
        viewer = newViewer
        renderThread.addViewer(newViewer)
        renderThread.post { newViewer.resize(width, height) }
        result.success(newViewer.textureId())
    }

    fun resize(width: Int, height: Int, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        current.setBufferSize(width, height)
        renderThread.post { current.resize(width, height) }
        result.success(null)
    }

    fun clearScene(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.clearScene()
            postSuccess(result)
        }
    }

    fun loadModelFromAsset(assetPath: String, result: Result) {
        val resolvedPath = flutterAssets.getAssetFilePathByName(assetPath)
        val baseDir = resolvedPath.substringBeforeLast('/', "")
        ioExecutor.execute {
            try {
                val buffer = readAssetBuffer(resolvedPath)
                renderThread.post {
                    val current = viewer
                    if (current == null) {
                        // Viewer disposed while loading
                        return@post
                    }
                    val resourceUris = current.beginModelLoad(buffer)
                    if (resourceUris == null) {
                        postError(result, "Failed to parse glTF asset.")
                        return@post
                    }
                    if (resourceUris.isEmpty()) {
                        current.finishModelLoad(emptyMap())
                        postSuccess(result)
                    } else {
                        loadAssetResourcesAsync(baseDir, resourceUris, current, result)
                    }
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load asset.")
            }
        }
    }

    fun loadModelFromUrl(url: String, result: Result) {
        ioExecutor.execute {
            try {
                val file = cacheManager.getOrDownload(url)
                val buffer = readFileBuffer(file)
                val baseUrl = url.substringBeforeLast("/")
                renderThread.post {
                    val current = viewer
                    if (current == null) {
                         // Viewer disposed while loading
                        return@post
                    }
                    val resourceUris = current.beginModelLoad(buffer)
                    if (resourceUris == null) {
                        postError(result, "Failed to parse glTF asset.")
                        return@post
                    }
                    if (resourceUris.isEmpty()) {
                        current.finishModelLoad(emptyMap())
                        postSuccess(result)
                    } else {
                        loadUrlResourcesAsync(baseUrl, resourceUris, current, result)
                    }
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load URL.")
            }
        }
    }

    fun loadModelFromFile(filePath: String, result: Result) {
        ioExecutor.execute {
            try {
                val file = File(filePath)
                if (!file.exists()) {
                    postError(result, "File not found.")
                    return@execute
                }
                val buffer = readFileBuffer(file)
                val baseDir = file.parentFile
                renderThread.post {
                    val current = viewer
                    if (current == null) {
                         // Viewer disposed while loading
                        return@post
                    }
                    val resourceUris = current.beginModelLoad(buffer)
                    if (resourceUris == null) {
                        postError(result, "Failed to parse glTF asset.")
                        return@post
                    }
                    if (resourceUris.isEmpty() || baseDir == null) {
                        current.finishModelLoad(emptyMap())
                        postSuccess(result)
                    } else {
                        loadFileResourcesAsync(baseDir, resourceUris, current, result)
                    }
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load file.")
            }
        }
    }

    fun setIBLFromAsset(assetPath: String, result: Result) {
        val resolvedPath = flutterAssets.getAssetFilePathByName(assetPath)
        ioExecutor.execute {
            try {
                val buffer = readAssetBuffer(resolvedPath)
                renderThread.post {
                    viewer?.setIndirectLightFromKtx(buffer)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load IBL asset.")
            }
        }
    }

    fun setSkyboxFromAsset(assetPath: String, result: Result) {
        val resolvedPath = flutterAssets.getAssetFilePathByName(assetPath)
        ioExecutor.execute {
            try {
                val buffer = readAssetBuffer(resolvedPath)
                renderThread.post {
                    viewer?.setSkyboxFromKtx(buffer)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load skybox asset.")
            }
        }
    }

    fun setHdriFromAsset(assetPath: String, result: Result) {
        val resolvedPath = flutterAssets.getAssetFilePathByName(assetPath)
        ioExecutor.execute {
            try {
                val buffer = readAssetBuffer(resolvedPath)
                renderThread.post {
                    try {
                        viewer?.setHdriFromHdr(buffer)
                        postSuccess(result)
                    } catch (e: Exception) {
                        postError(result, e.message ?: "Failed to load HDRI asset.")
                    }
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load HDRI asset.")
            }
        }
    }

    fun setIBLFromUrl(url: String, result: Result) {
        ioExecutor.execute {
            try {
                val file = cacheManager.getOrDownload(url)
                val buffer = readFileBuffer(file)
                renderThread.post {
                    viewer?.setIndirectLightFromKtx(buffer)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load IBL URL.")
            }
        }
    }

    fun setSkyboxFromUrl(url: String, result: Result) {
        ioExecutor.execute {
            try {
                val file = cacheManager.getOrDownload(url)
                val buffer = readFileBuffer(file)
                renderThread.post {
                    viewer?.setSkyboxFromKtx(buffer)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load skybox URL.")
            }
        }
    }

    fun setHdriFromUrl(url: String, result: Result) {
        ioExecutor.execute {
            try {
                val file = cacheManager.getOrDownload(url)
                val buffer = readFileBuffer(file)
                renderThread.post {
                    try {
                        viewer?.setHdriFromHdr(buffer)
                        postSuccess(result)
                    } catch (e: Exception) {
                        postError(result, e.message ?: "Failed to load HDRI URL.")
                    }
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load HDRI URL.")
            }
        }
    }

    fun frameModel(useWorldOrigin: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.frameModel(useWorldOrigin)
            postSuccess(result)
        }
    }

    fun setOrbitConstraints(
        minPitchDeg: Double,
        maxPitchDeg: Double,
        minYawDeg: Double,
        maxYawDeg: Double,
        result: Result,
    ) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setOrbitConstraints(minPitchDeg, maxPitchDeg, minYawDeg, maxYawDeg)
            postSuccess(result)
        }
    }

    fun setInertiaEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setInertiaEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setInertiaParams(damping: Double, sensitivity: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setInertiaParams(damping, sensitivity)
            postSuccess(result)
        }
    }

    fun setZoomLimits(minDistance: Double, maxDistance: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setZoomLimits(minDistance, maxDistance)
            postSuccess(result)
        }
    }

    fun setCustomCameraEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setCustomCameraEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setCustomCameraLookAt(
        eyeX: Double,
        eyeY: Double,
        eyeZ: Double,
        centerX: Double,
        centerY: Double,
        centerZ: Double,
        upX: Double,
        upY: Double,
        upZ: Double,
        result: Result,
    ) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setCustomCameraLookAt(eyeX, eyeY, eyeZ, centerX, centerY, centerZ, upX, upY, upZ)
            postSuccess(result)
        }
    }

    fun setCustomPerspective(fov: Double, near: Double, far: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setCustomPerspective(fov, near, far)
            postSuccess(result)
        }
    }

    fun getAnimationCount(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(0)
            return
        }
        renderThread.post {
            val count = current.getAnimationCount()
            mainHandler.post { result.success(count) }
        }
    }

    fun playAnimation(index: Int, loop: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.playAnimation(index, loop)
            postSuccess(result)
        }
    }

    fun pauseAnimation(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.pauseAnimation()
            postSuccess(result)
        }
    }

    fun seekAnimation(seconds: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.seekAnimation(seconds)
            postSuccess(result)
        }
    }

    fun setAnimationSpeed(speed: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setAnimationSpeed(speed)
            postSuccess(result)
        }
    }

    fun getAnimationDuration(index: Int, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(0.0)
            return
        }
        renderThread.post {
            val duration = current.getAnimationDuration(index)
            mainHandler.post { result.success(duration) }
        }
    }

    fun setMsaa(samples: Int, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setMsaa(samples)
            postSuccess(result)
        }
    }

    fun setDynamicResolutionEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setDynamicResolutionEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setToneMappingFilmic(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setToneMappingFilmic()
            postSuccess(result)
        }
    }

    fun setEnvironmentEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setEnvironmentEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setShadowsEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setShadowsEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setWireframeEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setWireframeEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setBoundingBoxesEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setBoundingBoxesEnabled(enabled)
            postSuccess(result)
        }
    }

    fun setDebugLoggingEnabled(enabled: Boolean, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.setDebugLoggingEnabled(enabled)
            postSuccess(result)
        }
    }

    fun orbitStart(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.orbitStart()
            postSuccess(result)
        }
    }

    fun orbitDelta(dx: Double, dy: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.orbitDelta(dx, dy)
            postSuccess(result)
        }
    }

    fun orbitEnd(velocityX: Double, velocityY: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.orbitEnd(velocityX, velocityY)
            postSuccess(result)
        }
    }

    fun zoomStart(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.zoomStart()
            postSuccess(result)
        }
    }

    fun zoomDelta(scaleDelta: Double, result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.zoomDelta(scaleDelta)
            postSuccess(result)
        }
    }

    fun zoomEnd(result: Result) {
        val current = viewer
        if (current == null) {
            result.success(null)
            return
        }
        renderThread.post {
            current.zoomEnd()
            postSuccess(result)
        }
    }

    fun getCacheSizeBytes(result: Result) {
        ioExecutor.execute {
            val size = cacheManager.getCacheSizeBytes()
            mainHandler.post { result.success(size) }
        }
    }

    fun clearCache(result: Result) {
        ioExecutor.execute {
            val success = cacheManager.clearCache()
            if (success) {
                postSuccess(result)
            } else {
                postError(result, "Failed to clear cache.")
            }
        }
    }

    fun dispose(result: Result) {
        disposeViewer()
        postSuccess(result)
    }

    fun disposeViewer() {
        val current = viewer ?: return
        renderThread.removeViewer(current)
        renderThread.post { current.destroy() }
        viewer = null
    }

    private fun loadAssetResourcesAsync(
        baseDir: String,
        resourceUris: List<String>,
        current: FilamentViewer,
        result: Result,
    ) {
        ioExecutor.execute {
            try {
                val resources = mutableMapOf<String, ByteBuffer>()
                for (uri in resourceUris) {
                    if (uri.startsWith("data:")) {
                        continue
                    }
                    val assetPath = if (baseDir.isEmpty()) uri else "$baseDir/$uri"
                    resources[uri] = readAssetBuffer(assetPath)
                }
                renderThread.post {
                    current.finishModelLoad(resources)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load glTF resources.")
            }
        }
    }

    private fun loadUrlResourcesAsync(
        baseUrl: String,
        resourceUris: List<String>,
        current: FilamentViewer,
        result: Result,
    ) {
        ioExecutor.execute {
            try {
                val resources = mutableMapOf<String, ByteBuffer>()
                for (uri in resourceUris) {
                    if (uri.startsWith("data:")) {
                        continue
                    }
                    val resourceUrl = if (uri.startsWith("http://") || uri.startsWith("https://")) {
                        uri
                    } else {
                        "$baseUrl/$uri"
                    }
                    val resourceFile = cacheManager.getOrDownload(resourceUrl)
                    resources[uri] = readFileBuffer(resourceFile)
                }
                renderThread.post {
                    current.finishModelLoad(resources)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load glTF resources.")
            }
        }
    }

    private fun loadFileResourcesAsync(
        baseDir: File,
        resourceUris: List<String>,
        current: FilamentViewer,
        result: Result,
    ) {
        ioExecutor.execute {
            try {
                val resources = mutableMapOf<String, ByteBuffer>()
                for (uri in resourceUris) {
                    if (uri.startsWith("data:")) {
                        continue
                    }
                    val resourceFile = when {
                        uri.startsWith("file://") -> {
                            val parsed = Uri.parse(uri)
                            val path = parsed.path
                            if (path.isNullOrEmpty()) continue
                            File(path)
                        }
                        uri.startsWith("/") -> File(uri)
                        else -> File(baseDir, uri)
                    }
                    resources[uri] = readFileBuffer(resourceFile)
                }
                renderThread.post {
                    current.finishModelLoad(resources)
                    postSuccess(result)
                }
            } catch (e: Exception) {
                postError(result, e.message ?: "Failed to load glTF resources.")
            }
        }
    }

    private fun readAssetBuffer(assetPath: String): ByteBuffer {
        context.assets.open(assetPath).use { input ->
            val bytes = input.readBytes()
            return bytes.toDirectBuffer()
        }
    }

    private fun readFileBuffer(file: File): ByteBuffer {
        val bytes = file.readBytes()
        return bytes.toDirectBuffer()
    }

    private fun ByteArray.toDirectBuffer(): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(size)
        buffer.order(ByteOrder.nativeOrder())
        buffer.put(this)
        buffer.flip()
        return buffer
    }

    private fun postSuccess(result: Result) {
        mainHandler.post { result.success(null) }
    }

    private fun postError(result: Result, message: String) {
        eventEmitter("error", message)
        mainHandler.post { result.error("filament_error", message, null) }
    }
}
