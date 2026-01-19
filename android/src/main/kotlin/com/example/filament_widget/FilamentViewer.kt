package com.example.filament_widget

import android.view.Surface
import com.google.android.filament.Camera
import com.google.android.filament.ColorGrading
import com.google.android.filament.EntityManager
import com.google.android.filament.Engine
import com.google.android.filament.IndirectLight
import com.google.android.filament.LightManager
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.Skybox
import com.google.android.filament.SwapChain
import com.google.android.filament.Texture
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.Animator
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.MaterialProvider
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import com.google.android.filament.utils.KTX1Loader
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer

class FilamentViewer(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val surface: Surface,
    private val eventEmitter: (String, String) -> Unit,
) {
    private val engine: Engine = FilamentEngineManager.getEngine()
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
    private var animator: Animator? = null
    private var animationIndex = 0
    private var animationLoop = true
    private var animationPlaying = false
    private var animationTimeSeconds = 0.0
    private var animationSpeed = 1.0
    private var lastAnimationFrameTimeNanos = 0L
    private var lightEntity: Int = 0
    private var indirectLight: IndirectLight? = null
    private var indirectLightCubemap: Texture? = null
    private var skybox: Skybox? = null
    private var skyboxCubemap: Texture? = null
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
    private var cameraFovDegrees = 45.0
    private var cameraNear = 0.05
    private var cameraFar = 100.0
    private var hasModelBounds = false
    private var modelCenter = doubleArrayOf(0.0, 0.0, 0.0)
    private var modelHalfExtent = doubleArrayOf(0.5, 0.5, 0.5)
    private var customCameraEnabled = false
    private var customLookAt = doubleArrayOf(0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    private var customPerspective = doubleArrayOf(45.0, 0.05, 100.0)

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
    }

    fun clearScene() {
        filamentAsset?.let { asset ->
            scene.removeEntities(asset.entities)
            assetLoader?.destroyAsset(asset)
        }
        filamentAsset = null
        pendingAsset = null
        animator = null
        animationPlaying = false
        animationTimeSeconds = 0.0
        lastAnimationFrameTimeNanos = 0L
        resourceLoader?.destroy()
        resourceLoader = null
        hasModelBounds = false
    }

    fun beginModelLoad(buffer: ByteBuffer): List<String>? {
        clearScene()
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
        loader.loadResources(asset)
        asset.releaseSourceData()
        scene.addEntities(asset.entities)
        filamentAsset = asset
        pendingAsset = null
        animator = asset.instance?.animator
        animationPlaying = false
        animationTimeSeconds = 0.0
        lastAnimationFrameTimeNanos = 0L
        updateBoundsFromAsset(asset)
        eventEmitter("modelLoaded", "Model loaded.")
    }

    fun destroy() {
        clearScene()
        materialProvider?.destroy()
        materialProvider = null
        indirectLight?.let { engine.destroyIndirectLight(it) }
        indirectLightCubemap?.let { engine.destroyTexture(it) }
        skybox?.let { engine.destroySkybox(it) }
        skyboxCubemap?.let { engine.destroyTexture(it) }
        colorGrading?.let { engine.destroyColorGrading(it) }
        indirectLight = null
        indirectLightCubemap = null
        skybox = null
        skyboxCubemap = null
        colorGrading = null
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

    fun setIndirectLightFromKtx(buffer: ByteBuffer) {
        val options = KTX1Loader.Options().apply { srgb = false }
        val bundle = KTX1Loader.createIndirectLight(engine, buffer, options)
        indirectLight?.let { engine.destroyIndirectLight(it) }
        indirectLightCubemap?.let { engine.destroyTexture(it) }
        indirectLight = bundle.indirectLight
        indirectLightCubemap = bundle.cubemap
        scene.indirectLight = indirectLight
    }

    fun setSkyboxFromKtx(buffer: ByteBuffer) {
        val options = KTX1Loader.Options().apply { srgb = true }
        val bundle = KTX1Loader.createSkybox(engine, buffer, options)
        skybox?.let { engine.destroySkybox(it) }
        skyboxCubemap?.let { engine.destroyTexture(it) }
        skybox = bundle.skybox
        skyboxCubemap = bundle.cubemap
        scene.skybox = skybox
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

    private fun updateProjection() {
        val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
        camera.setProjection(
            cameraFovDegrees,
            aspect,
            cameraNear,
            cameraFar,
            Camera.Fov.VERTICAL,
        )
    }

    private fun updateCamera(frameTimeNanos: Long) {
        if (customCameraEnabled) {
            val aspect = viewportWidth.toDouble() / viewportHeight.toDouble()
            val fov = customPerspective[0]
            val near = customPerspective[1]
            val far = customPerspective[2]
            camera.setProjection(fov, aspect, near, far, Camera.Fov.VERTICAL)
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
        val eye = orbitController.getEyePosition()
        camera.lookAt(
            eye[0],
            eye[1],
            eye[2],
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
}
