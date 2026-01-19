package com.example.filament_widget

import android.content.res.AssetManager
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
import com.google.android.filament.utils.KTX1Loader
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.util.Locale
import android.util.Log
import com.google.android.filament.Box
import com.google.android.filament.IndexBuffer
import com.google.android.filament.Colors

class FilamentViewer(
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val surface: Surface,
    private val assetManager: AssetManager,
    private val eventEmitter: (String, String) -> Unit,
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
    private var debugLineMaterial: Material? = null
    private var wireframeRenderable: DebugLineRenderable? = null
    private var boundsRenderable: DebugLineRenderable? = null
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
        updateFps(frameTimeNanos)
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
        destroyDebugRenderable(wireframeRenderable)
        destroyDebugRenderable(boundsRenderable)
        wireframeRenderable = null
        boundsRenderable = null
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
        rebuildWireframe()
        rebuildBoundingBoxes()
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
        wireframeEnabled = enabled
        rebuildWireframe()
    }

    fun setBoundingBoxesEnabled(enabled: Boolean) {
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

    private fun rebuildWireframe() {
        destroyDebugRenderable(wireframeRenderable)
        wireframeRenderable = null
        if (!wireframeEnabled) {
            return
        }
        val data = buildWireframeLineData() ?: return
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

    private fun buildWireframeLineData(): LineMeshData? {
        val asset = filamentAsset ?: return null
        val renderables = asset.renderableEntities
        if (renderables.isEmpty()) {
            return null
        }
        val tm = engine.transformManager
        val rm = engine.renderableManager
        val valid = mutableListOf<Int>()
        for (entity in renderables) {
            if (!tm.hasComponent(entity)) {
                continue
            }
            val instance = rm.getInstance(entity)
            if (instance != 0) {
                valid.add(entity)
            }
        }
        if (valid.isEmpty()) {
            return null
        }
        val positions = FloatArray(valid.size * 8 * 3)
        val indices = IntArray(valid.size * 24)
        val edgeIndices = intArrayOf(
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
        val world = FloatArray(16)
        var vIndex = 0
        var iIndex = 0
        for (entity in valid) {
            val renderable = rm.getInstance(entity)
            val transform = tm.getInstance(entity)
            tm.getWorldTransform(transform, world)
            val box = Box()
            rm.getAxisAlignedBoundingBox(renderable, box)
            val center = box.center
            val half = box.halfExtent
            val minX = center[0] - half[0]
            val minY = center[1] - half[1]
            val minZ = center[2] - half[2]
            val maxX = center[0] + half[0]
            val maxY = center[1] + half[1]
            val maxZ = center[2] + half[2]
            val corners = arrayOf(
                floatArrayOf(minX, minY, minZ),
                floatArrayOf(minX, minY, maxZ),
                floatArrayOf(minX, maxY, minZ),
                floatArrayOf(minX, maxY, maxZ),
                floatArrayOf(maxX, minY, minZ),
                floatArrayOf(maxX, minY, maxZ),
                floatArrayOf(maxX, maxY, minZ),
                floatArrayOf(maxX, maxY, maxZ),
            )
            val baseVertex = vIndex / 3
            for (corner in corners) {
                val transformed = transformPoint(world, corner[0], corner[1], corner[2])
                positions[vIndex++] = transformed[0]
                positions[vIndex++] = transformed[1]
                positions[vIndex++] = transformed[2]
            }
            for (edge in edgeIndices) {
                indices[iIndex++] = baseVertex + edge
            }
        }
        return LineMeshData(positions, indices)
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
}
