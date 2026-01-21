import Flutter
import Foundation

final class FilamentController {
  private let controllerId: Int
  private let textureRegistry: FlutterTextureRegistry
  private let renderLoop: FilamentRenderLoop
  private let cacheManager: FilamentCacheManager
  private let assetLookup: (String) -> String
  private let eventEmitter: (String, String) -> Void

  private var renderer: FilamentRenderer?
  private var texture: FilamentTexture?
  private var textureId: Int64 = 0

  init(
    controllerId: Int,
    textureRegistry: FlutterTextureRegistry,
    renderLoop: FilamentRenderLoop,
    cacheManager: FilamentCacheManager,
    assetLookup: @escaping (String) -> String,
    eventEmitter: @escaping (String, String) -> Void
  ) {
    self.controllerId = controllerId
    self.textureRegistry = textureRegistry
    self.renderLoop = renderLoop
    self.cacheManager = cacheManager
    self.assetLookup = assetLookup
    self.eventEmitter = eventEmitter
  }

  func createViewer(width: Int, height: Int, result: @escaping FlutterResult) {
    let clampedWidth = max(1, width)
    let clampedHeight = max(1, height)
    guard let pixelBuffer = makePixelBuffer(width: clampedWidth, height: clampedHeight) else {
      result(FlutterError(code: "filament_error", message: "Failed to allocate pixel buffer.", details: nil))
      return
    }
    let texture = FilamentTexture(pixelBuffer: pixelBuffer)
    let textureId = textureRegistry.register(texture)
    let renderer = FilamentRenderer()
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
    renderLoop.addRenderer(renderer)
    renderLoop.perform {
      renderer.setup(with: pixelBuffer, width: Int32(clampedWidth), height: Int32(clampedHeight))
    }
    result(textureId)
  }

  func resize(width: Int, height: Int, result: @escaping FlutterResult) {
    guard let renderer, let texture else {
      result(nil)
      return
    }
    let clampedWidth = max(1, width)
    let clampedHeight = max(1, height)
    guard let pixelBuffer = makePixelBuffer(width: clampedWidth, height: clampedHeight) else {
      result(FlutterError(code: "filament_error", message: "Failed to allocate pixel buffer.", details: nil))
      return
    }
    texture.updatePixelBuffer(pixelBuffer)
    renderLoop.perform {
      renderer.resize(with: pixelBuffer, width: Int32(clampedWidth), height: Int32(clampedHeight))
    }
    result(nil)
  }

  func clearScene(result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.clearScene()
      DispatchQueue.main.async { result(nil) }
    }
  }

  func loadModelFromAsset(assetPath: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    let key = assetLookup(assetPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result(FlutterError(code: "filament_error", message: "Asset not found: \(assetPath)", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          renderer.setResourcePath(url.path)
          let uris = renderer.beginModelLoad(data)
          DispatchQueue.main.async {
            self.handleResourceUris(
              uris,
              baseURL: url.deletingLastPathComponent(),
              mode: .asset,
              cacheRoot: nil,
              result: result
            )
          }
        }
      } catch {
        self.emitError("Failed to read asset data: \(error.localizedDescription)", result: result)
      }
    }
  }

  func loadModelFromUrl(urlString: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    guard let url = URL(string: urlString) else {
      result(FlutterError(code: "filament_error", message: "Invalid URL.", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
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
          renderer.setResourcePath(cached.path)
          let uris = renderer.beginModelLoad(data)
          DispatchQueue.main.async {
            self.handleResourceUris(
              uris,
              baseURL: url.deletingLastPathComponent(),
              mode: .remote,
              cacheRoot: cacheRoot,
              result: result
            )
          }
        }
      } catch {
        self.emitError("Failed to download model: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setIBLFromAsset(ktxPath: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    let key = assetLookup(ktxPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result(FlutterError(code: "filament_error", message: "Asset not found: \(ktxPath)", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          renderer.setIndirectLightFromKTX(data)
          DispatchQueue.main.async { result(nil) }
        }
      } catch {
        self.emitError("Failed to load IBL asset: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setSkyboxFromAsset(ktxPath: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    let key = assetLookup(ktxPath)
    guard let url = Bundle.main.url(forResource: key, withExtension: nil) else {
      result(FlutterError(code: "filament_error", message: "Asset not found: \(ktxPath)", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let data = try Data(contentsOf: url)
        self.renderLoop.perform {
          renderer.setSkyboxFromKTX(data)
          DispatchQueue.main.async { result(nil) }
        }
      } catch {
        self.emitError("Failed to load skybox asset: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setIBLFromUrl(urlString: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    guard let url = URL(string: urlString) else {
      result(FlutterError(code: "filament_error", message: "Invalid URL.", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          renderer.setIndirectLightFromKTX(data)
          DispatchQueue.main.async { result(nil) }
        }
      } catch {
        self.emitError("Failed to load IBL URL: \(error.localizedDescription)", result: result)
      }
    }
  }

  func setSkyboxFromUrl(urlString: String, result: @escaping FlutterResult) {
    guard let renderer else {
      result(FlutterError(code: "filament_error", message: "Viewer not initialized.", details: nil))
      return
    }
    guard let url = URL(string: urlString) else {
      result(FlutterError(code: "filament_error", message: "Invalid URL.", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          renderer.setSkyboxFromKTX(data)
          DispatchQueue.main.async { result(nil) }
        }
      } catch {
        self.emitError("Failed to load skybox URL: \(error.localizedDescription)", result: result)
      }
    }
  }

  func frameModel(useWorldOrigin: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.frameModel(useWorldOrigin)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setOrbitConstraints(
    minPitchDeg: Double,
    maxPitchDeg: Double,
    minYawDeg: Double,
    maxYawDeg: Double,
    result: @escaping FlutterResult
  ) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setOrbitConstraintsWithMinPitch(
        minPitchDeg,
        maxPitch: maxPitchDeg,
        minYaw: minYawDeg,
        maxYaw: maxYawDeg
      )
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setInertiaEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setInertiaEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setInertiaParams(damping: Double, sensitivity: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setInertiaParamsWithDamping(damping, sensitivity: sensitivity)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setZoomLimits(minDistance: Double, maxDistance: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setZoomLimitsWithMinDistance(minDistance, maxDistance: maxDistance)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setCustomCameraEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setCustomCameraEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
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
    result: @escaping FlutterResult
  ) {
    guard let renderer else {
      result(nil)
      return
    }
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
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setCustomPerspective(fovDegrees: Double, near: Double, far: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setCustomPerspectiveWithFov(fovDegrees, near: near, far: far)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func orbitStart(result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.orbitStart()
      DispatchQueue.main.async { result(nil) }
    }
  }

  func orbitDelta(dx: Double, dy: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.orbitDelta(withDx: dx, dy: dy)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func orbitEnd(velocityX: Double, velocityY: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.orbitEnd(withVelocityX: velocityX, velocityY: velocityY)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func zoomStart(result: @escaping FlutterResult) {
    result(nil)
  }

  func zoomDelta(scaleDelta: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.zoomDelta(scaleDelta)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func zoomEnd(result: @escaping FlutterResult) {
    result(nil)
  }

  func getAnimationCount(result: @escaping FlutterResult) {
    guard let renderer else {
      result(0)
      return
    }
    renderLoop.perform {
      let count = renderer.getAnimationCount()
      DispatchQueue.main.async { result(count) }
    }
  }

  func playAnimation(index: Int, loop: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.playAnimation(Int32(index), loop: loop)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func pauseAnimation(result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.pauseAnimation()
      DispatchQueue.main.async { result(nil) }
    }
  }

  func seekAnimation(seconds: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.seekAnimation(seconds)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setAnimationSpeed(speed: Double, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setAnimationSpeed(speed)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func getAnimationDuration(index: Int, result: @escaping FlutterResult) {
    guard let renderer else {
      result(0.0)
      return
    }
    renderLoop.perform {
      let duration = renderer.getAnimationDuration(Int32(index))
      DispatchQueue.main.async { result(duration) }
    }
  }

  func setMsaa(samples: Int, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setMsaa(Int32(samples))
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setDynamicResolutionEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setDynamicResolutionEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setToneMappingFilmic(result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setToneMappingFilmic()
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setShadowsEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setShadowsEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setWireframeEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setWireframeEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setBoundingBoxesEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setBoundingBoxesEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func setDebugLoggingEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
    guard let renderer else {
      result(nil)
      return
    }
    renderLoop.perform {
      renderer.setDebugLoggingEnabled(enabled)
      DispatchQueue.main.async { result(nil) }
    }
  }

  func getCacheSizeBytes(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async { [cacheManager] in
      let size = cacheManager.getCacheSizeBytes()
      DispatchQueue.main.async { result(size) }
    }
  }

  func clearCache(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async { [cacheManager] in
      let success = cacheManager.clearCache()
      DispatchQueue.main.async {
        if success {
          result(nil)
        } else {
          result(FlutterError(code: "filament_error", message: "Failed to clear cache.", details: nil))
        }
      }
    }
  }

  func dispose(result: @escaping FlutterResult) {
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
    result(nil)
  }

  private enum ResourceMode {
    case asset
    case remote
  }

  private func handleResourceUris(
    _ uris: [String],
    baseURL: URL,
    mode: ResourceMode,
    cacheRoot: URL?,
    result: @escaping FlutterResult
  ) {
    guard let renderer else {
      emitError("Viewer not initialized.", result: result)
      return
    }
    if uris.isEmpty {
      renderLoop.perform {
        let loaded = renderer.finishModelLoad([:])
        DispatchQueue.main.async {
          if loaded {
            self.eventEmitter("modelLoaded", "Model loaded.")
            result(nil)
          } else {
            self.emitError("Failed to load model resources.", result: result)
          }
        }
      }
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        var resources: [String: Data] = [:]
        for uri in uris {
          if uri.hasPrefix("data:") {
            continue
          }
          switch mode {
          case .asset:
            let resourceURL = baseURL.appendingPathComponent(uri)
            resources[uri] = try Data(contentsOf: resourceURL)
          case .remote:
            let resourceURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(uri)
            if let cacheRoot {
              let cached = try self.cacheManager.getOrDownload(
                url: resourceURL,
                cacheRoot: cacheRoot,
                relativePath: uri
              )
              resources[uri] = try Data(contentsOf: cached)
            } else {
              let cached = try self.cacheManager.getOrDownload(url: resourceURL)
              resources[uri] = try Data(contentsOf: cached)
            }
          }
        }
        self.renderLoop.perform {
          let loaded = renderer.finishModelLoad(resources)
          DispatchQueue.main.async {
            if loaded {
              self.eventEmitter("modelLoaded", "Model loaded.")
              result(nil)
            } else {
              self.emitError("Failed to load model resources.", result: result)
            }
          }
        }
      } catch {
        self.emitError("Failed to load resources: \(error.localizedDescription)", result: result)
      }
    }
  }

  private func emitError(_ message: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      self.eventEmitter("error", message)
      result(FlutterError(code: "filament_error", message: message, details: nil))
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
