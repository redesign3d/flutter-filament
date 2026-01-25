package com.example.filament_widget

import android.content.res.AssetManager
import android.net.Uri
import android.util.Base64
import android.view.Surface
import com.google.android.filament.Camera
import com.google.android.filament.ColorGrading
import com.google.android.filament.EntityManager
import com.google.android.filament.Engine
import com.google.android.filament.IndirectLight
import com.google.android.filament.LightManager
import com.google.android.filament.Material
import com.google.android.filament.MaterialInstance
import com.google.android.filament.RenderableManager
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.Skybox
import com.google.android.filament.SwapChain
import com.google.android.filament.Texture
import com.google.android.filament.VertexBuffer
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.Animator
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.MaterialProvider
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import com.google.android.filament.utils.HDRLoader
import com.google.android.filament.utils.IBLPrefilterContext
import com.google.android.filament.utils.KTX1Loader
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject
import android.util.Log
import com.google.android.filament.Box
import com.google.android.filament.IndexBuffer
import com.google.android.filament.Colors

class FilamentViewer(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val surface: Surface,
    private val assetManager: AssetManager,
    private val eventEmitter: (String, String) -> Unit,
    private val engine: Engine,
    private val debugFeaturesEnabled: Boolean,
) {
    private data class DebugLineRenderable(
        val entity: Int,
        val vertexBuffer: VertexBuffer,
        val indexBuffer: IndexBuffer,
        val materialInstance: MaterialInstance,
    )

    private data class LineMeshData(
        val positions: FloatArray,
        val indices: IntArray,
    )

    private data class GltfSource(
        val json: JSONObject,
        val binChunk: ByteArray?,
    )

    private data class BufferViewInfo(
        val buffer: Int,
        val byteOffset: Int,
        val byteLength: Int,
        val byteStride: Int,
    )

    private data class AccessorInfo(
        val bufferView: Int,
        val byteOffset: Int,
        val componentType: Int,
        val count: Int,
        val type: String,
        val hasSparse: Boolean,
    )

    private val renderer: Renderer = engine.createRenderer()
    private val view: View = engine.createView()
    private val scene: Scene = engine.createScene()
    private val cameraEntity: Int = EntityManager.get().create()
    private val camera: Camera = engine.createCamera(cameraEntity)
    private var swapChain: SwapChain? = null
    private var materialProvider: MaterialProvider? = null
    private var assetLoader: AssetLoader? = null
    private var resourceLoader: ResourceLoader? = null
    private var filamentAsset: FilamentAsset? = null
    private var pendingAsset: FilamentAsset? = null
    private var pendingModelData: ByteArray? = null
    private var tempResourceData: Map<String, ByteBuffer>? = null
    private var animator: Animator? = null
    private var animationIndex = 0
    private var animationLoop = true
    private var animationPlaying = false
    private var animationTimeSeconds = 0.0
    private var animationSpeed = 1.0
    private var lastAnimationFrameTimeNanos = 0L
    private var debugLineMaterial: Material? = null
    private var wireframeRenderable: DebugLineRenderable? = null
    private var boundsRenderable: DebugLineRenderable? = null
    private var wireframeLineData: LineMeshData? = null
    private var wireframeEnabled = false
    private var boundingBoxesEnabled = false
    private var debugLoggingEnabled = false
    private var fpsFrameCount = 0
    private var fpsStartTimeNanos = 0L
    private var lightEntity: Int = 0
    private var indirectLight: IndirectLight? = null
    private var indirectLightCubemap: Texture? = null
    private var skybox: Skybox? = null
    private var skyboxCubemap: Texture? = null

    private var currentIblKey: String? = null
    private var currentSkyboxKey: String? = null

    private var environmentEnabled = true
    private var paused = false
    private var viewportWidth = 1
    private var viewportHeight = 1
    private var msaaSamples = 2
    private var dynamicResolutionEnabled = true
    private val dynamicResolutionOptions = View.DynamicResolutionOptions().apply {
        minScale = 0.5f
        maxScale = 1.0f
        sharpness = 0.9f
        enabled = true
    }
    private var colorGrading: ColorGrading? = null
    private val orbitController = OrbitCameraController()
    private var gestureActive = false

    private var cameraFovDegrees = 45.0
    private var cameraNear = 0.05
    private var cameraFar = 100.0
    private var hasModelBounds = false
    private var modelCenter = doubleArrayOf(0.0, 0.0, 0.0)
    private var modelHalfExtent = doubleArrayOf(0.5, 0.5, 0.5)
    private var customCameraEnabled = false
    private var customLookAt = doubleArrayOf(0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    private var customPerspective = doubleArrayOf(45.0, 0.05, 100.0)

    // Optimization: scratch arrays and cache
    private val eyePosScratch = DoubleArray(3)
    private var lastProjFov = -1.0
    private var lastProjAspect = -1.0
    private var lastProjNear = -1.0
    private var lastProjFar = -1.0

    init {
        view.camera = camera
        view.scene = scene
        view.setSampleCount(msaaSamples)
        applyDynamicResolution()
        setToneMappingFilmic()
        view.setShadowingEnabled(true)
        setupLight()
        ensureAssetLoader()
        swapChain = engine.createSwapChain(surface)
        updateProjection()
    }

    fun textureId(): Long = textureEntry.id()

    fun resize(width: Int, height: Int) {
        viewportWidth = width.coerceAtLeast(1)
        viewportHeight = height.coerceAtLeast(1)
        view.viewport = Viewport(0, 0, viewportWidth, viewportHeight)
        if (customCameraEnabled) {
            val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
            camera.setProjection(
                customPerspective[0],
                aspect,
                customPerspective[1],
                customPerspective[2],
                Camera.Fov.VERTICAL,
            )
        } else {
            updateProjection()
        }
    }

    fun setBufferSize(width: Int, height: Int) {
        textureEntry.surfaceTexture().setDefaultBufferSize(width, height)
    }

    fun setPaused(paused: Boolean) {
        this.paused = paused
    }

    fun setGestureActive(active: Boolean) {
        gestureActive = active
    }

    fun wantsContinuousRendering(): Boolean {
        return animationPlaying || gestureActive || orbitController.isAnimating
    }

    fun render(frameTimeNanos: Long) {
        if (paused) {
            return
        }
        val swap = swapChain ?: return
        updateAnimation(frameTimeNanos)
        updateCamera(frameTimeNanos)
        if (!renderer.beginFrame(swap, frameTimeNanos)) {
            return
        }
        renderer.render(view)
        renderer.endFrame()
        updateFps(frameTimeNanos)
    }

    fun clearScene() {
        filamentAsset?.let { asset ->
            scene.removeEntities(asset.entities)
            assetLoader?.destroyAsset(asset)
        }
        filamentAsset = null
        pendingAsset?.let { asset ->
            assetLoader?.destroyAsset(asset)
        }
        pendingAsset = null
        pendingModelData = null
        animator = null
        animationPlaying = false
        animationTimeSeconds = 0.0
        lastAnimationFrameTimeNanos = 0L
        destroyDebugRenderable(wireframeRenderable)
        destroyDebugRenderable(boundsRenderable)
        wireframeRenderable = null
        boundsRenderable = null
        wireframeLineData = null
        resourceLoader?.destroy()
        resourceLoader = null
        hasModelBounds = false
    }

    fun beginModelLoad(buffer: ByteBuffer): List<String>? {
        clearScene()
        pendingModelData = buffer.toByteArray()
        val loader = ensureAssetLoader()
        val asset = loader.createAsset(buffer) ?: run {
            eventEmitter("error", "Failed to parse glTF asset.")
            return null
        }
        pendingAsset = asset
        return asset.resourceUris.toList()
    }

    fun finishModelLoad(resourceData: Map<String, ByteBuffer>) {
        val asset = pendingAsset ?: run {
            eventEmitter("error", "No pending asset to finalize.")
            return
        }
        val loader = resetResourceLoader()
        for ((uri, data) in resourceData) {
            loader.addResourceData(uri, data)
        }
        try {
            loader.loadResources(asset)
        } catch (e: Exception) {
            eventEmitter("error", "Failed to load glTF resources: ${e.message}")
            assetLoader?.destroyAsset(asset)
            pendingAsset = null
            pendingModelData = null
            return
        }
        asset.releaseSourceData()
        scene.addEntities(asset.entities)
        filamentAsset = asset
        pendingAsset = null
        
        // Debug data generation is offloaded to background thread
        if (debugFeaturesEnabled) {
            tempResourceData = resourceData
        } else {
            tempResourceData = null
        }
        
        animator = asset.instance?.animator
        animationPlaying = false
        animationTimeSeconds = 0.0
        lastAnimationFrameTimeNanos = 0L
        updateBoundsFromAsset(asset)
        
        eventEmitter("modelLoaded", "Model loaded.")
    }

    fun updateDebugDataInBackground() {
        if (!debugFeaturesEnabled) return
        val resources = tempResourceData ?: return
        wireframeLineData = buildWireframeLineData(resources)
    }

    fun applyDebugData() {
        if (debugFeaturesEnabled) {
            rebuildWireframe()
            rebuildBoundingBoxes()
        }
        tempResourceData = null
        pendingModelData = null
    }

    fun destroy() {
        clearScene()
        materialProvider?.destroy()
        materialProvider = null

        if (currentIblKey != null) {
            EnvironmentCache.release(currentIblKey!!, engine)
        } else {
            indirectLight?.let { engine.destroyIndirectLight(it) }
            indirectLightCubemap?.let { engine.destroyTexture(it) }
        }

        if (currentSkyboxKey != null) {
            EnvironmentCache.release(currentSkyboxKey!!, engine)
        } else {
            skybox?.let { engine.destroySkybox(it) }
            skyboxCubemap?.let { engine.destroyTexture(it) }
        }

        colorGrading?.let { engine.destroyColorGrading(it) }
        destroyDebugRenderable(wireframeRenderable)
        destroyDebugRenderable(boundsRenderable)
        debugLineMaterial?.let { engine.destroyMaterial(it) }
        
        indirectLight = null
        indirectLightCubemap = null
        skybox = null
        skyboxCubemap = null
        colorGrading = null
        debugLineMaterial = null
        wireframeRenderable = null
        boundsRenderable = null
        swapChain?.let { engine.destroySwapChain(it) }
        swapChain = null
        engine.destroyRenderer(renderer)
        engine.destroyView(view)
        engine.destroyScene(scene)
        engine.destroyCameraComponent(cameraEntity)
        if (lightEntity != 0) {
            engine.destroyEntity(lightEntity)
            lightEntity = 0
        }
        surface.release()
        textureEntry.release()
    }

    fun frameModel(useWorldOrigin: Boolean) {
        val target = if (useWorldOrigin || !hasModelBounds) {
            doubleArrayOf(0.0, 0.0, 0.0)
        } else {
            modelCenter
        }
        val radius = if (useWorldOrigin || !hasModelBounds) {
            1.0
        } else {
            orbitController.updateTargetFromBounds(modelCenter, modelHalfExtent)
        }
        val distance = orbitController.computeDistanceForRadius(radius, cameraFovDegrees)
        orbitController.reset(distance, target)
    }

    fun setOrbitConstraints(
        minPitchDeg: Double,
        maxPitchDeg: Double,
        minYawDeg: Double,
        maxYawDeg: Double,
    ) {
        orbitController.setOrbitConstraints(minPitchDeg, maxPitchDeg, minYawDeg, maxYawDeg)
    }

    fun setInertiaEnabled(enabled: Boolean) {
        orbitController.inertiaEnabled = enabled
    }

    fun setInertiaParams(damping: Double, sensitivity: Double) {
        orbitController.damping = damping
        orbitController.sensitivity = sensitivity
    }

    fun setZoomLimits(minDistance: Double, maxDistance: Double) {
        orbitController.setZoomLimits(minDistance, maxDistance)
    }

    fun orbitStart() {
        orbitController.orbitStart()
    }

    fun orbitDelta(dx: Double, dy: Double) {
        orbitController.orbitDelta(dx, dy)
    }

    fun orbitEnd(velocityX: Double, velocityY: Double) {
        orbitController.orbitEnd(velocityX, velocityY)
    }

    fun zoomStart() {}

    fun zoomDelta(scaleDelta: Double) {
        orbitController.zoomDelta(scaleDelta)
    }

    fun zoomEnd() {}

    fun getAnimationCount(): Int = animator?.animationCount ?: 0

    fun getAnimationDuration(index: Int): Double {
        val current = animator ?: return 0.0
        if (index < 0 || index >= current.animationCount) {
            return 0.0
        }
        return current.getAnimationDuration(index).toDouble()
    }

    fun playAnimation(index: Int, loop: Boolean) {
        val current = animator ?: return
        if (current.animationCount == 0) {
            return
        }
        animationIndex = index.coerceIn(0, current.animationCount - 1)
        animationLoop = loop
        animationPlaying = true
        animationTimeSeconds = 0.0
        lastAnimationFrameTimeNanos = 0L
        applyAnimationFrame(current, animationTimeSeconds)
    }

    fun pauseAnimation() {
        animationPlaying = false
        lastAnimationFrameTimeNanos = 0L
    }

    fun seekAnimation(seconds: Double) {
        val current = animator ?: return
        val duration = current.getAnimationDuration(animationIndex).toDouble()
        animationTimeSeconds = if (duration > 0.0) {
            seconds.coerceIn(0.0, duration)
        } else {
            seconds.coerceAtLeast(0.0)
        }
        applyAnimationFrame(current, animationTimeSeconds)
    }

    fun setAnimationSpeed(speed: Double) {
        animationSpeed = speed
    }

    fun setMsaa(samples: Int) {
        msaaSamples = when (samples) {
            2 -> 2
            4 -> 4
            else -> 1
        }
        view.setSampleCount(msaaSamples)
    }

    fun setDynamicResolutionEnabled(enabled: Boolean) {
        dynamicResolutionEnabled = enabled
        applyDynamicResolution()
    }

    fun setEnvironmentEnabled(enabled: Boolean) {
        environmentEnabled = enabled
        scene.skybox = if (enabled) skybox else null
    }

    fun setToneMappingFilmic() {
        val grading = ColorGrading.Builder()
            .toneMapping(ColorGrading.ToneMapping.FILMIC)
            .build(engine)
        colorGrading?.let { engine.destroyColorGrading(it) }
        colorGrading = grading
        view.setColorGrading(grading)
    }

    fun setShadowsEnabled(enabled: Boolean) {
        view.setShadowingEnabled(enabled)
    }

    fun setWireframeEnabled(enabled: Boolean) {
        if (enabled && !debugFeaturesEnabled) {
            logDebug("Ignoring setWireframeEnabled(true) because debugFeaturesEnabled is false.")
            return
        }
        wireframeEnabled = enabled
        rebuildWireframe()
    }

    fun setBoundingBoxesEnabled(enabled: Boolean) {
        if (enabled && !debugFeaturesEnabled) {
            logDebug("Ignoring setBoundingBoxesEnabled(true) because debugFeaturesEnabled is false.")
            return
        }
        boundingBoxesEnabled = enabled
        rebuildBoundingBoxes()
    }

    fun setDebugLoggingEnabled(enabled: Boolean) {
        debugLoggingEnabled = enabled
        logDebug("Debug logging ${if (enabled) "enabled" else "disabled"}.")
    }

    fun setCustomCameraEnabled(enabled: Boolean) {
        customCameraEnabled = enabled
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
    ) {
        customLookAt = doubleArrayOf(eyeX, eyeY, eyeZ, centerX, centerY, centerZ, upX, upY, upZ)
    }

    fun setCustomPerspective(fovDegrees: Double, near: Double, far: Double) {
        customPerspective = doubleArrayOf(fovDegrees, near, far)
    }

    fun setIndirectLightFromKtx(buffer: ByteBuffer, key: String? = null) {
        val cacheKey = if (key != null) "ibl_$key" else null
        var newIndirectLight: IndirectLight? = null
        var newIndirectLightCubemap: Texture? = null

        if (cacheKey != null) {
            val cached = EnvironmentCache.retain(cacheKey)
            if (cached != null) {
                newIndirectLight = cached.indirectLight
                newIndirectLightCubemap = cached.iblTexture
            }
        }

        if (newIndirectLight == null) {
            val options = KTX1Loader.Options().apply { srgb = false }
            val bundle = KTX1Loader.createIndirectLight(engine, buffer, options)
            newIndirectLight = bundle.indirectLight
            newIndirectLightCubemap = bundle.cubemap

            if (cacheKey != null) {
                EnvironmentCache.add(cacheKey, EnvironmentResource(newIndirectLight, null, null, newIndirectLightCubemap))
            }
        }

        if (currentIblKey != null) {
            EnvironmentCache.release(currentIblKey!!, engine)
        } else {
            indirectLight?.let { engine.destroyIndirectLight(it) }
            indirectLightCubemap?.let { engine.destroyTexture(it) }
        }

        indirectLight = newIndirectLight
        indirectLightCubemap = newIndirectLightCubemap
        scene.indirectLight = indirectLight
        currentIblKey = cacheKey
    }

    fun setSkyboxFromKtx(buffer: ByteBuffer, key: String? = null) {
        val cacheKey = if (key != null) "skybox_$key" else null
        var newSkybox: Skybox? = null
        var newSkyboxCubemap: Texture? = null

        if (cacheKey != null) {
            val cached = EnvironmentCache.retain(cacheKey)
            if (cached != null) {
                newSkybox = cached.skybox
                newSkyboxCubemap = cached.skyboxTexture
            }
        }

        if (newSkybox == null) {
            val options = KTX1Loader.Options().apply { srgb = true }
            val bundle = KTX1Loader.createSkybox(engine, buffer, options)
            newSkybox = bundle.skybox
            newSkyboxCubemap = bundle.cubemap

            if (cacheKey != null) {
                EnvironmentCache.add(cacheKey, EnvironmentResource(null, newSkybox, newSkyboxCubemap, null))
            }
        }

        if (currentSkyboxKey != null) {
            EnvironmentCache.release(currentSkyboxKey!!, engine)
        } else {
            skybox?.let { engine.destroySkybox(it) }
            skyboxCubemap?.let { engine.destroyTexture(it) }
        }

        skybox = newSkybox
        skyboxCubemap = newSkyboxCubemap
        scene.skybox = if (environmentEnabled) skybox else null
        currentSkyboxKey = cacheKey
    }

    fun setHdriFromHdr(buffer: ByteBuffer, key: String? = null) {
        val cacheKey = if (key != null) "hdr_$key" else null
        
        var newIndirectLight: IndirectLight? = null
        var newSkybox: Skybox? = null
        var newIblTex: Texture? = null
        var newSkyTex: Texture? = null

        if (cacheKey != null) {
            val cached = EnvironmentCache.retain(cacheKey)
            if (cached != null) {
                newIndirectLight = cached.indirectLight
                newSkybox = cached.skybox
                newSkyTex = cached.skyboxTexture
                newIblTex = cached.iblTexture
                EnvironmentCache.retain(cacheKey)
            }
        }

        if (newIndirectLight == null) {
            val hdrOptions = HDRLoader.Options().apply {
                desiredFormat = Texture.InternalFormat.R11F_G11F_B10F
            }
            val hdrTexture = HDRLoader.createTexture(engine, buffer, hdrOptions)
            
            if (hdrTexture == null) {
                eventEmitter("error", "Failed to decode HDRI texture.")
                return
            }

            val iblContext = IBLPrefilterContext(engine)
            val equirectToCubemap = IBLPrefilterContext.EquirectangularToCubemap(iblContext)
            val cubemap = equirectToCubemap.run(hdrTexture)
            equirectToCubemap.destroy()
            val specularFilter = IBLPrefilterContext.SpecularFilter(iblContext)
            val specularCubemap = specularFilter.run(cubemap)
            specularFilter.destroy()
            iblContext.destroy()
            engine.destroyTexture(hdrTexture)

            newIndirectLight = IndirectLight.Builder()
                .reflections(specularCubemap)
                .irradiance(cubemap)
                .build(engine)
            newIblTex = specularCubemap

            newSkybox = Skybox.Builder().environment(cubemap).build(engine)
            newSkyTex = cubemap

            if (cacheKey != null) {
                val res = EnvironmentResource(newIndirectLight, newSkybox, newSkyTex, newIblTex)
                EnvironmentCache.add(cacheKey, res)
                EnvironmentCache.retain(cacheKey)
            }
        }

        if (currentIblKey != null) {
            EnvironmentCache.release(currentIblKey!!, engine)
        } else {
            indirectLight?.let { engine.destroyIndirectLight(it) }
            indirectLightCubemap?.let { engine.destroyTexture(it) }
        }
        
        if (currentSkyboxKey != null) {
            EnvironmentCache.release(currentSkyboxKey!!, engine)
        } else {
            skybox?.let { engine.destroySkybox(it) }
            skyboxCubemap?.let { engine.destroyTexture(it) }
        }

        indirectLight = newIndirectLight
        indirectLightCubemap = newIblTex
        scene.indirectLight = indirectLight

        skybox = newSkybox
        skyboxCubemap = newSkyTex
        scene.skybox = if (environmentEnabled) skybox else null
        
        currentIblKey = cacheKey
        currentSkyboxKey = cacheKey
    }

    private fun ensureAssetLoader(): AssetLoader {
        if (materialProvider == null) {
            materialProvider = UbershaderProvider(engine)
        }
        if (assetLoader == null) {
            assetLoader = AssetLoader(engine, materialProvider!!, EntityManager.get())
        }
        return assetLoader!!
    }

    private fun resetResourceLoader(): ResourceLoader {
        resourceLoader?.destroy()
        resourceLoader = ResourceLoader(engine)
        return resourceLoader!!
    }

    private fun setupLight() {
        lightEntity = EntityManager.get().create()
        LightManager.Builder(LightManager.Type.DIRECTIONAL)
            .color(1.0f, 1.0f, 1.0f)
            .intensity(100_000.0f)
            .direction(0.0f, -1.0f, -0.5f)
            .castShadows(true)
            .build(engine, lightEntity)
        scene.addEntity(lightEntity)
    }

    private fun setProjectionIfNeeded(fov: Double, aspect: Double, near: Double, far: Double) {
        if (fov == lastProjFov && aspect == lastProjAspect && near == lastProjNear && far == lastProjFar) {
            return
        }
        camera.setProjection(fov, aspect, near, far, Camera.Fov.VERTICAL)
        lastProjFov = fov
        lastProjAspect = aspect
        lastProjNear = near
        lastProjFar = far
    }

    private fun updateProjection() {
        val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
        setProjectionIfNeeded(cameraFovDegrees, aspect, cameraNear, cameraFar)
    }

    private fun updateCamera(frameTimeNanos: Long) {
        if (customCameraEnabled) {
            val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
            setProjectionIfNeeded(
                customPerspective[0],
                aspect,
                customPerspective[1],
                customPerspective[2]
            )
            camera.lookAt(
                customLookAt[0],
                customLookAt[1],
                customLookAt[2],
                customLookAt[3],
                customLookAt[4],
                customLookAt[5],
                customLookAt[6],
                customLookAt[7],
                customLookAt[8],
            )
            return
        }
        orbitController.update(frameTimeNanos)
        orbitController.getEyePosition(eyePosScratch)
        camera.lookAt(
            eyePosScratch[0],
            eyePosScratch[1],
            eyePosScratch[2],
            orbitController.targetX,
            orbitController.targetY,
            orbitController.targetZ,
            0.0,
            1.0,
            0.0,
        )
        updateProjection()
    }

    private fun applyDynamicResolution() {
        dynamicResolutionOptions.enabled = dynamicResolutionEnabled
        view.setDynamicResolutionOptions(dynamicResolutionOptions)
    }

    private fun rebuildWireframe() {
        destroyDebugRenderable(wireframeRenderable)
        wireframeRenderable = null
        if (!wireframeEnabled) {
            return
        }
        val data = wireframeLineData ?: return
        wireframeRenderable = buildDebugRenderable(
            data,
            floatArrayOf(0.0f, 0.85f, 1.0f, 0.6f),
        )
        wireframeRenderable?.let { scene.addEntity(it.entity) }
        logDebug("Wireframe renderable updated.")
    }

    private fun rebuildBoundingBoxes() {
        destroyDebugRenderable(boundsRenderable)
        boundsRenderable = null
        if (!boundingBoxesEnabled) {
            return
        }
        val data = buildBoundingBoxLineData() ?: return
        boundsRenderable = buildDebugRenderable(
            data,
            floatArrayOf(1.0f, 0.3f, 0.3f, 0.8f),
        )
        boundsRenderable?.let { scene.addEntity(it.entity) }
        logDebug("Bounding box renderable updated.")
    }

    private fun buildWireframeLineData(resourceData: Map<String, ByteBuffer>): LineMeshData? {
        val source = pendingModelData ?: return null
        val gltf = parseGltfSource(source) ?: return null
        val json = gltf.json
        val accessorsJson = json.optJSONArray("accessors") ?: return null
        val bufferViewsJson = json.optJSONArray("bufferViews") ?: return null
        val buffersJson = json.optJSONArray("buffers") ?: return null
        val meshesJson = json.optJSONArray("meshes") ?: return null
        val nodesJson = json.optJSONArray("nodes") ?: JSONArray()
        val resourceMap = buildResourceDataMap(resourceData)
        val bufferData = resolveBufferDataList(buffersJson, resourceMap, gltf.binChunk) ?: return null
        val bufferViews = parseBufferViews(bufferViewsJson)
        val accessors = parseAccessors(accessorsJson)
        val nodeWorld = buildNodeWorldMatrices(json, nodesJson)
        val positionsOut = ArrayList<Float>()
        val indicesOut = ArrayList<Int>()
        for (nodeIndex in 0 until nodesJson.length()) {
            val node = nodesJson.optJSONObject(nodeIndex) ?: continue
            val meshIndex = node.optInt("mesh", -1)
            if (meshIndex < 0 || meshIndex >= meshesJson.length()) {
                continue
            }
            val mesh = meshesJson.optJSONObject(meshIndex) ?: continue
            val primitives = mesh.optJSONArray("primitives") ?: continue
            val world = if (nodeWorld.isNotEmpty()) nodeWorld[nodeIndex] else identityMatrix()
            for (p in 0 until primitives.length()) {
                val primitive = primitives.optJSONObject(p) ?: continue
                val attributes = primitive.optJSONObject("attributes") ?: continue
                val positionAccessorIndex = attributes.optInt("POSITION", -1)
                if (positionAccessorIndex < 0 || positionAccessorIndex >= accessors.size) {
                    continue
                }
                val positions = readAccessorVec3(
                    accessors[positionAccessorIndex],
                    bufferViews,
                    bufferData,
                ) ?: continue
                val vertexCount = positions.size / 3
                if (vertexCount == 0) {
                    continue
                }
                val transformed = FloatArray(positions.size)
                var cursor = 0
                while (cursor < positions.size) {
                    val transformedPoint = transformPosition(
                        world,
                        positions[cursor],
                        positions[cursor + 1],
                        positions[cursor + 2],
                    )
                    transformed[cursor] = transformedPoint[0]
                    transformed[cursor + 1] = transformedPoint[1]
                    transformed[cursor + 2] = transformedPoint[2]
                    cursor += 3
                }
                val baseVertex = positionsOut.size / 3
                for (value in transformed) {
                    positionsOut.add(value)
                }
                val indices = if (primitive.has("indices")) {
                    val indexAccessorIndex = primitive.optInt("indices", -1)
                    if (indexAccessorIndex >= 0 && indexAccessorIndex < accessors.size) {
                        readAccessorIndices(accessors[indexAccessorIndex], bufferViews, bufferData)
                    } else {
                        null
                    }
                } else {
                    IntArray(vertexCount) { it }
                } ?: continue
                val mode = primitive.optInt("mode", 4)
                val edges = buildWireframeEdges(indices, mode) ?: continue
                for (edge in edges) {
                    indicesOut.add(baseVertex + edge)
                }
            }
        }
        if (positionsOut.isEmpty() || indicesOut.isEmpty()) {
            return null
        }
        var minX = positionsOut[0]
        var maxX = positionsOut[0]
        var minY = positionsOut[1]
        var maxY = positionsOut[1]
        var minZ = positionsOut[2]
        var maxZ = positionsOut[2]
        var i = 0
        while (i + 2 < positionsOut.size) {
            val x = positionsOut[i]
            val y = positionsOut[i + 1]
            val z = positionsOut[i + 2]
            if (x < minX) minX = x
            if (x > maxX) maxX = x
            if (y < minY) minY = y
            if (y > maxY) maxY = y
            if (z < minZ) minZ = z
            if (z > maxZ) maxZ = z
            i += 3
        }
        val cx = (minX + maxX) * 0.5f
        val cy = (minY + maxY) * 0.5f
        val cz = (minZ + maxZ) * 0.5f
        val scale = 1.01f
        i = 0
        while (i + 2 < positionsOut.size) {
            positionsOut[i] = cx + (positionsOut[i] - cx) * scale
            positionsOut[i + 1] = cy + (positionsOut[i + 1] - cy) * scale
            positionsOut[i + 2] = cz + (positionsOut[i + 2] - cz) * scale
            i += 3
        }
        return LineMeshData(positionsOut.toFloatArray(), indicesOut.toIntArray())
    }

    private fun parseGltfSource(data: ByteArray): GltfSource? {
        if (data.size >= 12) {
            val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            val magic = buffer.int
            if (magic == 0x46546C67) {
                buffer.int
                val length = buffer.int
                if (length > data.size || length < 12) {
                    return null
                }
                var jsonChunk: ByteArray? = null
                var binChunk: ByteArray? = null
                while (buffer.remaining() >= 8) {
                    val chunkLength = buffer.int
                    val chunkType = buffer.int
                    if (chunkLength < 0 || chunkLength > buffer.remaining()) {
                        return null
                    }
                    val chunkData = ByteArray(chunkLength)
                    buffer.get(chunkData)
                    when (chunkType) {
                        0x4E4F534A -> jsonChunk = chunkData
                        0x004E4942 -> binChunk = chunkData
                    }
                }
                val jsonBytes = jsonChunk ?: return null
                return GltfSource(JSONObject(String(jsonBytes, Charsets.UTF_8)), binChunk)
            }
        }
        return GltfSource(JSONObject(String(data, Charsets.UTF_8)), null)
    }

    private fun buildResourceDataMap(resourceData: Map<String, ByteBuffer>): Map<String, ByteArray> {
        val map = mutableMapOf<String, ByteArray>()
        for ((key, buffer) in resourceData) {
            val bytes = buffer.toByteArray()
            map[key] = bytes
            val decoded = Uri.decode(key)
            if (decoded != key) {
                map[decoded] = bytes
            }
            if (key.startsWith("./")) {
                map[key.removePrefix("./")] = bytes
            }
            val lastSegment = key.substringAfterLast('/')
            if (lastSegment != key) {
                map[lastSegment] = bytes
            }
        }
        return map
    }

    private fun resolveBufferDataList(
        buffersJson: JSONArray,
        resourceMap: Map<String, ByteArray>,
        embeddedBin: ByteArray?,
    ): List<ByteArray>? {
        val buffers = ArrayList<ByteArray>(buffersJson.length())
        for (i in 0 until buffersJson.length()) {
            val buffer = buffersJson.optJSONObject(i) ?: return null
            val uri = buffer.optString("uri", "")
            val data = if (uri.isNotEmpty()) {
                resolveBufferData(uri, resourceMap, embeddedBin)
            } else {
                embeddedBin
            }
            if (data == null) {
                return null
            }
            buffers.add(data)
        }
        return buffers
    }

    private fun resolveBufferData(
        uri: String,
        resourceMap: Map<String, ByteArray>,
        embeddedBin: ByteArray?,
    ): ByteArray? {
        if (uri.startsWith("data:")) {
            return decodeDataUri(uri)
        }
        return resourceMap[uri]
            ?: resourceMap[Uri.decode(uri)]
            ?: resourceMap[uri.removePrefix("./")]
            ?: resourceMap[uri.substringAfterLast('/')]
            ?: embeddedBin
    }

    private fun decodeDataUri(uri: String): ByteArray? {
        val commaIndex = uri.indexOf(',')
        if (commaIndex == -1) {
            return null
        }
        val metadata = uri.substring(5, commaIndex)
        val dataPart = uri.substring(commaIndex + 1)
        return if (metadata.endsWith(";base64")) {
            Base64.decode(dataPart, Base64.DEFAULT)
        } else {
            Uri.decode(dataPart).toByteArray(Charsets.UTF_8)
        }
    }

    private fun parseBufferViews(bufferViewsJson: JSONArray): List<BufferViewInfo> {
        val list = ArrayList<BufferViewInfo>(bufferViewsJson.length())
        for (i in 0 until bufferViewsJson.length()) {
            val view = bufferViewsJson.optJSONObject(i) ?: continue
            list.add(
                BufferViewInfo(
                    buffer = view.optInt("buffer", -1),
                    byteOffset = view.optInt("byteOffset", 0),
                    byteLength = view.optInt("byteLength", 0),
                    byteStride = view.optInt("byteStride", 0),
                ),
            )
        }
        return list
    }

    private fun parseAccessors(accessorsJson: JSONArray): List<AccessorInfo> {
        val list = ArrayList<AccessorInfo>(accessorsJson.length())
        for (i in 0 until accessorsJson.length()) {
            val accessor = accessorsJson.optJSONObject(i) ?: continue
            list.add(
                AccessorInfo(
                    bufferView = accessor.optInt("bufferView", -1),
                    byteOffset = accessor.optInt("byteOffset", 0),
                    componentType = accessor.optInt("componentType", -1),
                    count = accessor.optInt("count", 0),
                    type = accessor.optString("type", ""),
                    hasSparse = accessor.has("sparse"),
                ),
            )
        }
        return list
    }

    private fun readAccessorVec3(
        accessor: AccessorInfo,
        bufferViews: List<BufferViewInfo>,
        buffers: List<ByteArray>,
    ): FloatArray? {
        if (accessor.bufferView < 0 || accessor.type != "VEC3" || accessor.componentType != 5126) {
            return null
        }
        if (accessor.hasSparse) {
            return null
        }
        val view = bufferViews.getOrNull(accessor.bufferView) ?: return null
        val buffer = buffers.getOrNull(view.buffer) ?: return null
        val stride = if (view.byteStride > 0) view.byteStride else 12
        val offset = view.byteOffset + accessor.byteOffset
        if (offset < 0 || offset >= buffer.size) {
            return null
        }
        val expectedEnd = offset + stride * max(0, accessor.count - 1) + 12
        if (expectedEnd > buffer.size) {
            return null
        }
        val result = FloatArray(accessor.count * 3)
        val byteBuffer = ByteBuffer.wrap(buffer).order(ByteOrder.LITTLE_ENDIAN)
        var cursor = offset
        var resultIndex = 0
        repeat(accessor.count) {
            byteBuffer.position(cursor)
            result[resultIndex++] = byteBuffer.float
            result[resultIndex++] = byteBuffer.float
            result[resultIndex++] = byteBuffer.float
            cursor += stride
        }
        return result
    }

    private fun readAccessorIndices(
        accessor: AccessorInfo,
        bufferViews: List<BufferViewInfo>,
        buffers: List<ByteArray>,
    ): IntArray? {
        if (accessor.bufferView < 0 || accessor.type != "SCALAR") {
            return null
        }
        if (accessor.hasSparse) {
            return null
        }
        val view = bufferViews.getOrNull(accessor.bufferView) ?: return null
        val buffer = buffers.getOrNull(view.buffer) ?: return null
        val componentSize = when (accessor.componentType) {
            5121 -> 1
            5123 -> 2
            5125 -> 4
            else -> return null
        }
        val stride = if (view.byteStride > 0) view.byteStride else componentSize
        val offset = view.byteOffset + accessor.byteOffset
        if (offset < 0 || offset >= buffer.size) {
            return null
        }
        val expectedEnd = offset + stride * max(0, accessor.count - 1) + componentSize
        if (expectedEnd > buffer.size) {
            return null
        }
        val result = IntArray(accessor.count)
        val byteBuffer = ByteBuffer.wrap(buffer).order(ByteOrder.LITTLE_ENDIAN)
        var cursor = offset
        for (i in 0 until accessor.count) {
            byteBuffer.position(cursor)
            result[i] = when (accessor.componentType) {
                5121 -> byteBuffer.get().toInt() and 0xFF
                5123 -> byteBuffer.short.toInt() and 0xFFFF
                5125 -> byteBuffer.int
                else -> 0
            }
            cursor += stride
        }
        return result
    }

    private fun buildWireframeEdges(indices: IntArray, mode: Int): IntArray? {
        if (indices.size < 3) {
            return null
        }
        val edges = ArrayList<Int>()
        val seen = HashSet<Long>()
        fun addEdge(a: Int, b: Int) {
            val minIndex = min(a, b)
            val maxIndex = max(a, b)
            val key = (minIndex.toLong() shl 32) or (maxIndex.toLong() and 0xffffffffL)
            if (seen.add(key)) {
                edges.add(a)
                edges.add(b)
            }
        }
        when (mode) {
            4 -> {
                val triangleCount = indices.size / 3
                for (i in 0 until triangleCount) {
                    val base = i * 3
                    val a = indices[base]
                    val b = indices[base + 1]
                    val c = indices[base + 2]
                    addEdge(a, b)
                    addEdge(b, c)
                    addEdge(c, a)
                }
            }
            5 -> {
                for (i in 0 until indices.size - 2) {
                    var a = indices[i]
                    var b = indices[i + 1]
                    var c = indices[i + 2]
                    if (i % 2 == 1) {
                        val temp = b
                        b = c
                        c = temp
                    }
                    addEdge(a, b)
                    addEdge(b, c)
                    addEdge(c, a)
                }
            }
            6 -> {
                val first = indices[0]
                for (i in 1 until indices.size - 1) {
                    val a = first
                    val b = indices[i]
                    val c = indices[i + 1]
                    addEdge(a, b)
                    addEdge(b, c)
                    addEdge(c, a)
                }
            }
            else -> return null
        }
        return edges.toIntArray()
    }

    private fun buildNodeWorldMatrices(
        json: JSONObject,
        nodesJson: JSONArray,
    ): Array<DoubleArray> {
        val count = nodesJson.length()
        if (count == 0) {
            return emptyArray()
        }
        val localMatrices = Array(count) { identityMatrix() }
        val children = Array(count) { IntArray(0) }
        val hasParent = BooleanArray(count)
        for (i in 0 until count) {
            val node = nodesJson.optJSONObject(i) ?: continue
            localMatrices[i] = parseNodeMatrix(node)
            val childrenArray = node.optJSONArray("children")
            if (childrenArray != null) {
                val list = IntArray(childrenArray.length())
                for (j in 0 until childrenArray.length()) {
                    val childIndex = childrenArray.optInt(j, -1)
                    list[j] = childIndex
                    if (childIndex in 0 until count) {
                        hasParent[childIndex] = true
                    }
                }
                children[i] = list
            }
        }
        val world = Array(count) { identityMatrix() }
        val roots = mutableListOf<Int>()
        val scenes = json.optJSONArray("scenes")
        val sceneIndex = json.optInt("scene", 0)
        if (scenes != null && scenes.length() > 0) {
            val scene = scenes.optJSONObject(sceneIndex.coerceIn(0, scenes.length() - 1))
            val sceneNodes = scene?.optJSONArray("nodes")
            if (sceneNodes != null) {
                for (i in 0 until sceneNodes.length()) {
                    val nodeIndex = sceneNodes.optInt(i, -1)
                    if (nodeIndex in 0 until count) {
                        roots.add(nodeIndex)
                    }
                }
            }
        }
        if (roots.isEmpty()) {
            for (i in 0 until count) {
                if (!hasParent[i]) {
                    roots.add(i)
                }
            }
        }
        if (roots.isEmpty()) {
            return world
        }
        for (root in roots) {
            computeWorldMatrix(root, identityMatrix(), localMatrices, children, world)
        }
        return world
    }

    private fun computeWorldMatrix(
        index: Int,
        parent: DoubleArray,
        locals: Array<DoubleArray>,
        children: Array<IntArray>,
        output: Array<DoubleArray>,
    ) {
        if (index !in output.indices) {
            return
        }
        val world = multiplyMatrices(parent, locals[index])
        output[index] = world
        for (child in children[index]) {
            computeWorldMatrix(child, world, locals, children, output)
        }
    }

    private fun parseNodeMatrix(node: JSONObject): DoubleArray {
        val matrixArray = node.optJSONArray("matrix")
        if (matrixArray != null && matrixArray.length() == 16) {
            val matrix = DoubleArray(16)
            for (i in 0 until 16) {
                matrix[i] = matrixArray.optDouble(i, if (i % 5 == 0) 1.0 else 0.0)
            }
            return matrix
        }
        val translation = node.optJSONArray("translation")
        val rotation = node.optJSONArray("rotation")
        val scale = node.optJSONArray("scale")
        val tx = translation?.optDouble(0, 0.0) ?: 0.0
        val ty = translation?.optDouble(1, 0.0) ?: 0.0
        val tz = translation?.optDouble(2, 0.0) ?: 0.0
        val qx = rotation?.optDouble(0, 0.0) ?: 0.0
        val qy = rotation?.optDouble(1, 0.0) ?: 0.0
        val qz = rotation?.optDouble(2, 0.0) ?: 0.0
        val qw = rotation?.optDouble(3, 1.0) ?: 1.0
        val sx = scale?.optDouble(0, 1.0) ?: 1.0
        val sy = scale?.optDouble(1, 1.0) ?: 1.0
        val sz = scale?.optDouble(2, 1.0) ?: 1.0
        val t = translationMatrix(tx, ty, tz)
        val r = rotationMatrix(qx, qy, qz, qw)
        val s = scaleMatrix(sx, sy, sz)
        return multiplyMatrices(t, multiplyMatrices(r, s))
    }

    private fun identityMatrix(): DoubleArray = doubleArrayOf(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )

    private fun translationMatrix(tx: Double, ty: Double, tz: Double): DoubleArray = doubleArrayOf(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        tx, ty, tz, 1.0,
    )

    private fun scaleMatrix(sx: Double, sy: Double, sz: Double): DoubleArray = doubleArrayOf(
        sx, 0.0, 0.0, 0.0,
        0.0, sy, 0.0, 0.0,
        0.0, 0.0, sz, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )

    private fun rotationMatrix(qx: Double, qy: Double, qz: Double, qw: Double): DoubleArray {
        val xx = qx * qx
        val yy = qy * qy
        val zz = qz * qz
        val xy = qx * qy
        val xz = qx * qz
        val yz = qy * qz
        val wx = qw * qx
        val wy = qw * qy
        val wz = qw * qz
        val m00 = 1.0 - 2.0 * (yy + zz)
        val m01 = 2.0 * (xy - wz)
        val m02 = 2.0 * (xz + wy)
        val m10 = 2.0 * (xy + wz)
        val m11 = 1.0 - 2.0 * (xx + zz)
        val m12 = 2.0 * (yz - wx)
        val m20 = 2.0 * (xz - wy)
        val m21 = 2.0 * (yz + wx)
        val m22 = 1.0 - 2.0 * (xx + yy)
        return doubleArrayOf(
            m00, m10, m20, 0.0,
            m01, m11, m21, 0.0,
            m02, m12, m22, 0.0,
            0.0, 0.0, 0.0, 1.0,
        )
    }

    private fun multiplyMatrices(a: DoubleArray, b: DoubleArray): DoubleArray {
        val out = DoubleArray(16)
        for (c in 0..3) {
            val col = c * 4
            val b0 = b[col]
            val b1 = b[col + 1]
            val b2 = b[col + 2]
            val b3 = b[col + 3]
            out[col] = a[0] * b0 + a[4] * b1 + a[8] * b2 + a[12] * b3
            out[col + 1] = a[1] * b0 + a[5] * b1 + a[9] * b2 + a[13] * b3
            out[col + 2] = a[2] * b0 + a[6] * b1 + a[10] * b2 + a[14] * b3
            out[col + 3] = a[3] * b0 + a[7] * b1 + a[11] * b2 + a[15] * b3
        }
        return out
    }

    private fun transformPosition(matrix: DoubleArray, x: Float, y: Float, z: Float): FloatArray {
        val tx = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12]
        val ty = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13]
        val tz = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14]
        return floatArrayOf(tx.toFloat(), ty.toFloat(), tz.toFloat())
    }

    private fun buildBoundingBoxLineData(): LineMeshData? {
        if (!hasModelBounds) {
            return null
        }
        val center = modelCenter
        val half = modelHalfExtent
        val minX = (center[0] - half[0]).toFloat()
        val minY = (center[1] - half[1]).toFloat()
        val minZ = (center[2] - half[2]).toFloat()
        val maxX = (center[0] + half[0]).toFloat()
        val maxY = (center[1] + half[1]).toFloat()
        val maxZ = (center[2] + half[2]).toFloat()
        val positions = floatArrayOf(
            minX,
            minY,
            minZ,
            minX,
            minY,
            maxZ,
            minX,
            maxY,
            minZ,
            minX,
            maxY,
            maxZ,
            maxX,
            minY,
            minZ,
            maxX,
            minY,
            maxZ,
            maxX,
            maxY,
            minZ,
            maxX,
            maxY,
            maxZ,
        )
        val indices = intArrayOf(
            0,
            1,
            1,
            3,
            3,
            2,
            2,
            0,
            4,
            5,
            5,
            7,
            7,
            6,
            6,
            4,
            0,
            4,
            2,
            6,
            1,
            5,
            3,
            7,
        )
        return LineMeshData(positions, indices)
    }

    private fun buildDebugRenderable(
        data: LineMeshData,
        color: FloatArray,
    ): DebugLineRenderable? {
        val material = ensureDebugMaterial() ?: return null
        val vertexBuffer = VertexBuffer.Builder()
            .bufferCount(1)
            .vertexCount(data.positions.size / 3)
            .attribute(VertexBuffer.VertexAttribute.POSITION, 0, VertexBuffer.AttributeType.FLOAT3)
            .build(engine)
        val indexBuffer = IndexBuffer.Builder()
            .indexCount(data.indices.size)
            .bufferType(IndexBuffer.Builder.IndexType.UINT)
            .build(engine)
        val vertexData = ByteBuffer.allocateDirect(data.positions.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        vertexData.put(data.positions)
        vertexData.flip()
        val indexData = ByteBuffer.allocateDirect(data.indices.size * 4)
            .order(ByteOrder.nativeOrder())
            .asIntBuffer()
        indexData.put(data.indices)
        indexData.flip()
        vertexBuffer.setBufferAt(engine, 0, vertexData)
        indexBuffer.setBuffer(engine, indexData)
        val instance = material.createInstance()
        instance.setParameter(
            "color",
            Colors.RgbaType.LINEAR,
            color[0],
            color[1],
            color[2],
            color[3],
        )
        val entity = EntityManager.get().create()
        RenderableManager.Builder(1)
            .culling(false)
            .castShadows(false)
            .receiveShadows(false)
            .material(0, instance)
            .geometry(0, RenderableManager.PrimitiveType.LINES, vertexBuffer, indexBuffer)
            .build(engine, entity)
        return DebugLineRenderable(entity, vertexBuffer, indexBuffer, instance)
    }

    private fun destroyDebugRenderable(renderable: DebugLineRenderable?) {
        if (renderable == null) {
            return
        }
        scene.removeEntity(renderable.entity)
        engine.destroyVertexBuffer(renderable.vertexBuffer)
        engine.destroyIndexBuffer(renderable.indexBuffer)
        engine.destroyMaterialInstance(renderable.materialInstance)
        engine.destroyEntity(renderable.entity)
    }

    private fun ensureDebugMaterial(): Material? {
        if (debugLineMaterial != null) {
            return debugLineMaterial
        }
        return try {
            assetManager.open("filament/wireframe.filamat").use { input ->
                val bytes = input.readBytes()
                val buffer = ByteBuffer.allocateDirect(bytes.size)
                buffer.order(ByteOrder.nativeOrder())
                buffer.put(bytes)
                buffer.flip()
                val material = Material.Builder()
                    .payload(buffer, buffer.remaining())
                    .build(engine)
                debugLineMaterial = material
                material
            }
        } catch (e: Exception) {
            logDebug("Failed to load wireframe material: ${e.message}")
            null
        }
    }

    private fun transformPoint(matrix: FloatArray, x: Float, y: Float, z: Float): FloatArray {
        val tx = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12]
        val ty = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13]
        val tz = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14]
        return floatArrayOf(tx, ty, tz)
    }

    private fun updateFps(frameTimeNanos: Long) {
        if (fpsStartTimeNanos == 0L) {
            fpsStartTimeNanos = frameTimeNanos
            fpsFrameCount = 0
        }
        fpsFrameCount += 1
        val elapsed = frameTimeNanos - fpsStartTimeNanos
        if (elapsed >= 1_000_000_000L) {
            val fpsValue = fpsFrameCount * 1_000_000_000.0 / elapsed.toDouble()
            eventEmitter("fps", String.format(Locale.US, "%.2f", fpsValue))
            fpsStartTimeNanos = frameTimeNanos
            fpsFrameCount = 0
        }
    }

    private fun logDebug(message: String) {
        if (debugLoggingEnabled) {
            Log.d("FilamentWidget", message)
        }
    }

    private fun updateAnimation(frameTimeNanos: Long) {
        val current = animator ?: return
        if (!animationPlaying) {
            return
        }
        if (lastAnimationFrameTimeNanos == 0L) {
            lastAnimationFrameTimeNanos = frameTimeNanos
            return
        }
        val deltaSeconds = (frameTimeNanos - lastAnimationFrameTimeNanos) / 1_000_000_000.0
        lastAnimationFrameTimeNanos = frameTimeNanos
        val duration = current.getAnimationDuration(animationIndex).toDouble()
        if (duration <= 0.0) {
            return
        }
        animationTimeSeconds += deltaSeconds * animationSpeed
        if (animationLoop) {
            animationTimeSeconds = ((animationTimeSeconds % duration) + duration) % duration
        } else {
            if (animationTimeSeconds >= duration) {
                animationTimeSeconds = duration
                animationPlaying = false
            } else if (animationTimeSeconds < 0.0) {
                animationTimeSeconds = 0.0
                animationPlaying = false
            }
        }
        applyAnimationFrame(current, animationTimeSeconds)
    }

    private fun applyAnimationFrame(animator: Animator, timeSeconds: Double) {
        animator.applyAnimation(animationIndex, timeSeconds.toFloat())
        animator.updateBoneMatrices()
    }

    private fun updateBoundsFromAsset(asset: FilamentAsset) {
        val box = asset.boundingBox
        val center = box.center
        val extent = box.halfExtent
        modelCenter = doubleArrayOf(center[0].toDouble(), center[1].toDouble(), center[2].toDouble())
        modelHalfExtent = doubleArrayOf(
            extent[0].toDouble(),
            extent[1].toDouble(),
            extent[2].toDouble(),
        )
        hasModelBounds = true
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val copy = duplicate()
        val bytes = ByteArray(copy.remaining())
        copy.get(bytes)
        return bytes
    }
}
