import Flutter
import Foundation

final class FilamentController {
  private enum FilamentControllerLifecycleState: String {
    case newState = "New"
    case initialized = "Initialized"
    case viewerReady = "ViewerReady"
    case disposing = "Disposing"
    case disposed = "Disposed"
  }

  private let controllerId: Int
  private let textureRegistry: FlutterTextureRegistry
  private let renderLoop: FilamentRenderLoop
  private let cacheManager: FilamentCacheManager
  private let assetLookup: (String) -> String
  private let eventEmitter: (String, String) -> Void
  private let debugFeaturesEnabled: Bool

  private var renderer: FilamentRenderer?
  private var texture: FilamentTexture?
  private var textureId: Int64 = 0
  private var disposed = false
  private var state: FilamentControllerLifecycleState = .newState

  init(
    controllerId: Int,
    textureRegistry: FlutterTextureRegistry,
    renderLoop: FilamentRenderLoop,
    cacheManager: FilamentCacheManager,
    assetLookup: @escaping (String) -> String,
    debugFeaturesEnabled: Bool,
    eventEmitter: @escaping (String, String) -> Void
  ) {
    self.controllerId = controllerId
    self.textureRegistry = textureRegistry
    self.renderLoop = renderLoop
    self.cacheManager = cacheManager
    self.assetLookup = assetLookup
    self.debugFeaturesEnabled = debugFeaturesEnabled
    self.eventEmitter = eventEmitter
    transition(to: .initialized)
  }

  deinit {
    // Ensure cleanup if dispose wasn't called explicitly
    if renderer != nil {
      dispose(result: { _ in })
    }
  }

  private func ensureRenderer(_ result: FilamentResultOnce) -> FilamentRenderer? {
    if disposed {
      result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
      return nil
    }
    guard let renderer else {
      result.error(code: FilamentErrors.noViewer, message: "Viewer not initialized.")
      return nil
    }
    return renderer
  }

  private func transition(to next: FilamentControllerLifecycleState) {
    guard state != next else { return }
    NSLog("[FilamentController] Controller %d state %@ -> %@", controllerId, state.rawValue, next.rawValue)
    state = next
    if next == .disposing || next == .disposed {
      disposed = true
    }
  }

  func createViewer(width: Int, height: Int, result: FilamentResultOnce) {
    if disposed {
      result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
      return
    }
    let clampedWidth = max(1, width)
    let clampedHeight = max(1, height)
    guard let pixelBuffer = makePixelBuffer(width: clampedWidth, height: clampedHeight) else {
      result.error(code: FilamentErrors.native, message: "Failed to allocate pixel buffer.")
      return
    }
    let texture = FilamentTexture(pixelBuffer: pixelBuffer)
    let textureId = textureRegistry.register(texture)
    let renderer = FilamentRenderer()
    renderer.setDebugFeaturesEnabled(debugFeaturesEnabled)
    renderer.setFpsCallback { [weak self] fps in
      guard let self else { return }
      let message = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), fps)
      self.eventEmitter("fps", message)
    }
    renderer.setFrameCallback { [weak self] in
      guard let self else { return }
      DispatchQueue.main.async {
        self.textureRegistry.textureFrameAvailable(textureId)
      }
    }
    self.texture = texture
    self.textureId = textureId
    self.renderer = renderer
    transition(to: .viewerReady)
    renderLoop.addRenderer(renderer)
    // Initial render
    renderLoop.requestFrame()
    renderLoop.perform {
      renderer.setup(with: pixelBuffer, width: Int32(clampedWidth), height: Int32(clampedHeight))
    }
    result.success(textureId)
  }

  func resize(width: Int, height: Int, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    guard let texture else {
      result.error(code: FilamentErrors.noViewer, message: "Viewer not initialized.")
      return
    }
    let clampedWidth = max(1, width)
    let clampedHeight = max(1, height)
    guard let pixelBuffer = makePixelBuffer(width: clampedWidth, height: clampedHeight) else {
      result.error(code: FilamentErrors.native, message: "Failed to allocate pixel buffer.")
      return
    }
    texture.updatePixelBuffer(pixelBuffer)
    renderLoop.perform {
      renderer.resize(with: pixelBuffer, width: Int32(clampedWidth), height: Int32(clampedHeight))
      // Trigger a frame after resize
    }
    renderLoop.requestFrame()
    result.success(nil)
  }

  func clearScene(result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.clearScene()
      result.success(nil)
    }
    renderLoop.requestFrame()
  }

  func loadModelFromAsset(assetPath: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    let key = assetLookup(assetPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result.error(code: FilamentErrors.io, message: "Asset not found: \(assetPath)")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setResourcePath(url.path)
          let uris = renderer.beginModelLoad(data)
          self.handleResourceUris(
            uris,
            baseURL: url.deletingLastPathComponent(),
            mode: .asset,
            cacheRoot: nil,
            result: result
          )
        }
      } catch {
        result.error(code: FilamentErrors.io, message: "Failed to read asset data: \(error.localizedDescription)")
      }
    }
  }

  func loadModelFromUrl(urlString: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    guard let url = URL(string: urlString) else {
      result.error(code: FilamentErrors.invalidArgs, message: "Invalid URL.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let isGltf = url.pathExtension.lowercased() == "gltf"
        let cacheRoot: URL?
        let cached: URL
        if isGltf {
          let modelDir = try self.cacheManager.modelCacheDirectory(for: url)
          cached = try self.cacheManager.getOrDownload(
            url: url,
            cacheRoot: modelDir,
            relativePath: url.lastPathComponent
          )
          cacheRoot = modelDir
        } else {
          cached = try self.cacheManager.getOrDownload(url: url)
          cacheRoot = nil
        }
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setResourcePath(cached.path)
          let uris = renderer.beginModelLoad(data)
          self.handleResourceUris(
            uris,
            baseURL: url.deletingLastPathComponent(),
            mode: .remote,
            cacheRoot: cacheRoot,
            result: result
          )
        }
      } catch {
        result.error(code: FilamentErrors.io, message: "Failed to download model: \(error.localizedDescription)")
      }
    }
  }

  func loadModelFromFile(filePath: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      result.error(code: FilamentErrors.io, message: "File not found.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let data = try Data(contentsOf: fileURL)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setResourcePath(fileURL.path)
          let uris = renderer.beginModelLoad(data)
          self.handleResourceUris(
            uris,
            baseURL: fileURL.deletingLastPathComponent(),
            mode: .localFile,
            cacheRoot: nil,
            result: result
          )
        }
      } catch {
        result.error(code: FilamentErrors.io, message: "Failed to read local file: \(error.localizedDescription)")
      }
    }
  }

  func setIBLFromAsset(ktxPath: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    let key = assetLookup(ktxPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result.error(code: FilamentErrors.io, message: "Asset not found: \(ktxPath)")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setIndirectLightFromKTX(data, key: ktxPath)
          result.success(nil)
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load IBL asset: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setSkyboxFromAsset(ktxPath: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    let key = assetLookup(ktxPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result.error(code: FilamentErrors.io, message: "Asset not found: \(ktxPath)")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setSkyboxFromKTX(data, key: ktxPath)
          result.success(nil)
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load skybox asset: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setHdriFromAsset(hdrPath: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    let key = assetLookup(hdrPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result.error(code: FilamentErrors.io, message: "Asset not found: \(hdrPath)")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          var message: NSString?
          let success = renderer.setHdriFromHDR(data, key: hdrPath, error: &message)
          if success {
            result.success(nil)
          } else {
            let errorMessage = message as String? ?? "Failed to load HDRI asset."
            self.emitError(FilamentErrors.native, message: errorMessage, result: result)
          }
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load HDRI asset: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setIBLFromUrl(urlString: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    guard let url = URL(string: urlString) else {
      result.error(code: FilamentErrors.invalidArgs, message: "Invalid URL.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setIndirectLightFromKTX(data, key: urlString)
          result.success(nil)
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load IBL URL: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setHdriFromUrl(urlString: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    guard let url = URL(string: urlString) else {
      result.error(code: FilamentErrors.invalidArgs, message: "Invalid URL.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          var message: NSString?
          let success = renderer.setHdriFromHDR(data, key: urlString, error: &message)
          if success {
            result.success(nil)
          } else {
            let errorMessage = message as String? ?? "Failed to load HDRI URL."
            self.emitError(FilamentErrors.native, message: errorMessage, result: result)
          }
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load HDRI URL: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setSkyboxFromUrl(urlString: String, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    guard let url = URL(string: urlString) else {
      result.error(code: FilamentErrors.invalidArgs, message: "Invalid URL.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          renderer.setSkyboxFromKTX(data, key: urlString)
          result.success(nil)
        }
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load skybox URL: \(error.localizedDescription)", result: result)
      }
    }
  }

  func frameModel(useWorldOrigin: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.frameModel(useWorldOrigin)
      result.success(nil)
    }
  }

  func setOrbitConstraints(
    minPitchDeg: Double,
    maxPitchDeg: Double,
    minYawDeg: Double,
    maxYawDeg: Double,
    result: FilamentResultOnce
  ) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setOrbitConstraintsWithMinPitch(
        minPitchDeg,
        maxPitch: maxPitchDeg,
        minYaw: minYawDeg,
        maxYaw: maxYawDeg
      )
      result.success(nil)
    }
  }

  func setInertiaEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setInertiaEnabled(enabled)
      result.success(nil)
    }
  }

  func setInertiaParams(damping: Double, sensitivity: Double, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setInertiaParamsWithDamping(damping, sensitivity: sensitivity)
      result.success(nil)
    }
  }

  func setZoomLimits(minDistance: Double, maxDistance: Double, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setZoomLimitsWithMinDistance(minDistance, maxDistance: maxDistance)
      result.success(nil)
    }
  }

  func setCustomCameraEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setCustomCameraEnabled(enabled)
      result.success(nil)
    }
  }

  func setCustomCameraLookAt(
    eyeX: Double,
    eyeY: Double,
    eyeZ: Double,
    centerX: Double,
    centerY: Double,
    centerZ: Double,
    upX: Double,
    upY: Double,
    upZ: Double,
    result: FilamentResultOnce
  ) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setCustomCameraLookAtWithEyeX(
        eyeX,
        eyeY: eyeY,
        eyeZ: eyeZ,
        centerX: centerX,
        centerY: centerY,
        centerZ: centerZ,
        upX: upX,
        upY: upY,
        upZ: upZ
      )
      result.success(nil)
    }
  }

  func setCustomPerspective(fovDegrees: Double, near: Double, far: Double, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setCustomPerspectiveWithFov(fovDegrees, near: near, far: far)
      result.success(nil)
    }
  }

  func orbitStart(result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.orbitStart()
      result.success(nil)
    }
  }

  func orbitDelta(dx: Double, dy: Double, result: FilamentResultOnce) {
    guard let renderer else {
      result.success(nil)
      return
    }
    renderLoop.perform {
      renderer.orbitDelta(withDx: dx, dy: dy)
      result.success(nil)
    }
  }

  func orbitDelta(dx: Double, dy: Double) {
    guard let renderer else { return }
    renderLoop.perform {
      renderer.orbitDelta(withDx: dx, dy: dy)
    }
    renderLoop.requestFrame()
  }

  func orbitEnd(velocityX: Double, velocityY: Double, result: FilamentResultOnce) {
    guard let renderer else {
      result.success(nil)
      return
    }
    renderLoop.perform {
      renderer.orbitEnd(withVelocityX: velocityX, velocityY: velocityY)
      result.success(nil)
    }
  }

  func setGestureActive(_ active: Bool) {
    guard let renderer else { return }
    renderLoop.perform {
      renderer.setGestureActive(active)
    }
    renderLoop.requestFrame()
  }

  func zoomStart(result: FilamentResultOnce) {
    result.success(nil)
  }

  func zoomDelta(scaleDelta: Double, result: FilamentResultOnce) {
    guard let renderer else {
      result.success(nil)
      return
    }
    renderLoop.perform {
      renderer.zoomDelta(scaleDelta)
      result.success(nil)
    }
    renderLoop.requestFrame()
  }
  func zoomDelta(scaleDelta: Double) {
    guard let renderer else { return }
    renderLoop.perform {
      renderer.zoomDelta(scaleDelta)
    }
    renderLoop.requestFrame()
  }
  func zoomEnd(result: FilamentResultOnce) {
    result.success(nil)
  }

  func getAnimationCount(result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      let count = renderer.getAnimationCount()
      result.success(count)
    }
  }

  func playAnimation(index: Int, loop: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.playAnimation(Int32(index), loop: loop)
      result.success(nil)
    }
  }

  func pauseAnimation(result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.pauseAnimation()
      result.success(nil)
    }
  }

  func seekAnimation(seconds: Double, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.seekAnimation(seconds)
      result.success(nil)
    }
  }

  func setAnimationSpeed(speed: Double, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setAnimationSpeed(speed)
      result.success(nil)
    }
  }

  func getAnimationDuration(index: Int, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      let duration = renderer.getAnimationDuration(Int32(index))
      result.success(duration)
    }
  }

  func setMsaa(samples: Int, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setMsaa(Int32(samples))
      result.success(nil)
    }
  }

  func setDynamicResolutionEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setDynamicResolutionEnabled(enabled)
      result.success(nil)
    }
  }

  func setEnvironmentEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setEnvironmentEnabled(enabled)
      result.success(nil)
    }
  }

  func setToneMappingFilmic(result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setToneMappingFilmic()
      result.success(nil)
    }
  }

  func setShadowsEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setShadowsEnabled(enabled)
      result.success(nil)
    }
  }

  func setWireframeEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    if enabled && !debugFeaturesEnabled {
      result.success(nil)
      return
    }

    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setWireframeEnabled(enabled)
      result.success(nil)
    }
  }

  func setBoundingBoxesEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    if enabled && !debugFeaturesEnabled {
      result.success(nil)
      return
    }
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setBoundingBoxesEnabled(enabled)
      result.success(nil)
    }
  }

  func setDebugLoggingEnabled(_ enabled: Bool, result: FilamentResultOnce) {
    guard let renderer = ensureRenderer(result) else { return }
    renderLoop.perform {
      renderer.setDebugLoggingEnabled(enabled)
      result.success(nil)
    }
  }

  func getCacheSizeBytes(result: FilamentResultOnce) {
    if disposed {
      result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
      return
    }
    DispatchQueue.global(qos: .utility).async { [cacheManager] in
      let size = cacheManager.getCacheSizeBytes()
      result.success(size)
    }
  }

  func clearCache(result: FilamentResultOnce) {
    if disposed {
      result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
      return
    }
    DispatchQueue.global(qos: .utility).async { [cacheManager] in
      let success = cacheManager.clearCache()
      if success {
        result.success(nil)
      } else {
        result.error(code: FilamentErrors.io, message: "Failed to clear cache.")
      }
    }
  }

  func dispose(result: @escaping FlutterResult) {
    dispose(result: FilamentResultOnce(result))
  }

  func dispose(result: FilamentResultOnce) {
    if state == .disposed || state == .disposing {
      result.success(nil)
      return
    }
    transition(to: .disposing)
    if let renderer {
      renderLoop.removeRenderer(renderer)
      renderLoop.perform {
        renderer.destroy()
      }
    }
    if textureId != 0 {
      textureRegistry.unregisterTexture(textureId)
    }
    texture = nil
    renderer = nil
    transition(to: .disposed)
    result.success(nil)
  }

  private enum ResourceMode {
    case asset
    case remote
    case localFile
  }

  private func handleResourceUris(
    _ uris: [String],
    baseURL: URL,
    mode: ResourceMode,
    cacheRoot: URL?,
    result: FilamentResultOnce
  ) {
    if disposed {
      result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
      return
    }
    guard let renderer else {
      emitError(FilamentErrors.noViewer, message: "Viewer not initialized.", result: result)
      return
    }
    if uris.isEmpty {
      renderLoop.perform {
        if self.disposed {
          result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
          return
        }
        let loaded = renderer.finishModelLoad([:])
        if loaded {
          DispatchQueue.main.async {
            self.eventEmitter("modelLoaded", "Model loaded.")
            result.success(nil)
          }
        } else {
          self.emitError(FilamentErrors.native, message: "Failed to load model resources.", result: result)
        }
      }
      renderLoop.requestFrame()
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
        return
      }
      do {
        var resourceData: [String: Data] = [:]
        for uri in uris where !uri.hasPrefix("data:") {
          let resourceURL: URL
          if uri.hasPrefix("file://"), let url = URL(string: uri) {
            resourceURL = url
          } else if uri.hasPrefix("/") {
            resourceURL = URL(fileURLWithPath: uri)
          } else {
            resourceURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(uri)
          }
          if mode == .remote {
            let cached: URL
            if let cacheRoot {
              cached = try self.cacheManager.getOrDownload(
                url: resourceURL,
                cacheRoot: cacheRoot,
                relativePath: uri
              )
            } else {
              cached = try self.cacheManager.getOrDownload(url: resourceURL)
            }
            resourceData[uri] = try Data(contentsOf: cached)
          } else {
            resourceData[uri] = try Data(contentsOf: resourceURL)
          }
        }
        self.renderLoop.perform {
          if self.disposed {
            result.error(code: FilamentErrors.disposed, message: "Controller disposed.")
            return
          }
          let loaded = renderer.finishModelLoad(resourceData)
          if loaded {
            DispatchQueue.main.async {
              self.eventEmitter("modelLoaded", "Model loaded.")
              result.success(nil)
            }
          } else {
            self.emitError(FilamentErrors.native, message: "Failed to load model resources.", result: result)
          }
        }
        self.renderLoop.requestFrame()
      } catch {
        self.emitError(FilamentErrors.io, message: "Failed to load resources: \(error.localizedDescription)", result: result)
      }
    }
  }

  private func emitError(_ code: String, message: String, result: FilamentResultOnce) {
    DispatchQueue.main.async {
      self.eventEmitter("error", message)
      result.error(code: code, message: message)
    }
  }

  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &buffer
    )
    if status != kCVReturnSuccess {
      return nil
    }
    return buffer
  }
}
