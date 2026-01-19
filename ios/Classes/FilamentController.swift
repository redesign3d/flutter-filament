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
          let uris = renderer.beginModelLoad(data)
          DispatchQueue.main.async {
            self.handleResourceUris(
              uris,
              baseURL: url.deletingLastPathComponent(),
              mode: .asset,
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
        let cached = try self.cacheManager.getOrDownload(url: url)
        let data = try Data(contentsOf: cached)
        self.renderLoop.perform {
          let uris = renderer.beginModelLoad(data)
          DispatchQueue.main.async {
            self.handleResourceUris(
              uris,
              baseURL: url.deletingLastPathComponent(),
              mode: .remote,
              result: result
            )
          }
        }
      } catch {
        self.emitError("Failed to download model: \(error.localizedDescription)", result: result)
      }
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
    result: @escaping FlutterResult
  ) {
    guard let renderer else {
      emitError("Viewer not initialized.", result: result)
      return
    }
    if uris.isEmpty {
      renderLoop.perform {
        renderer.finishModelLoad([:])
      }
      eventEmitter("modelLoaded", "Model loaded.")
      result(nil)
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
            let cached = try self.cacheManager.getOrDownload(url: resourceURL)
            resources[uri] = try Data(contentsOf: cached)
          }
        }
        self.renderLoop.perform {
          renderer.finishModelLoad(resources)
        }
        DispatchQueue.main.async {
          self.eventEmitter("modelLoaded", "Model loaded.")
          result(nil)
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
