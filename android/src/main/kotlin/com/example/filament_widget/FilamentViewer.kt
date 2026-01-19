package com.example.filament_widget

import android.view.Surface
import com.google.android.filament.Camera
import com.google.android.filament.EntityManager
import com.google.android.filament.Engine
import com.google.android.filament.LightManager
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.SwapChain
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.MaterialProvider
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
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
    private var lightEntity: Int = 0
    private var paused = false
    private var viewportWidth = 1
    private var viewportHeight = 1

    init {
        view.camera = camera
        view.scene = scene
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
        updateProjection()
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
        resourceLoader?.destroy()
        resourceLoader = null
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
        eventEmitter("modelLoaded", "Model loaded.")
    }

    fun destroy() {
        clearScene()
        materialProvider?.destroy()
        materialProvider = null
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
            45.0,
            aspect,
            0.05,
            100.0,
            Camera.Fov.VERTICAL,
        )
    }
}
