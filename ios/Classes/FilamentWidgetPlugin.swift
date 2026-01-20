import Flutter
import UIKit

public class FilamentWidgetPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private weak var registrar: FlutterPluginRegistrar?
  private var textureRegistry: FlutterTextureRegistry?
  private var assetLookup: ((String) -> String)?
  private lazy var renderLoop = FilamentRenderLoop.shared
  private lazy var cacheManager = FilamentCacheManager()
  private var controllers: [Int: FilamentController] = [:]
  private var eventSinks: [Int: FlutterEventSink] = [:]
  private var observingLifecycle = false

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    NSLog("[FilamentWidget] register start")
    let messenger = registrar.messenger()
    NSLog("[FilamentWidget] messenger ready")
    let channel = FlutterMethodChannel(name: "filament_widget", binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(name: "filament_widget/events", binaryMessenger: messenger)
    NSLog("[FilamentWidget] channels ready")
    let instance = FilamentWidgetPlugin(registrar: registrar)
    NSLog("[FilamentWidget] instance created")
    registrar.addMethodCallDelegate(instance, channel: channel)
    eventChannel.setStreamHandler(instance)
    NSLog("[FilamentWidget] register done")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createController":
      handleCreateController(call, result: result)
    case "disposeController":
      handleDisposeController(call, result: result)
    case "createViewer":
      handleCreateViewer(call, result: result)
    case "resize":
      handleResize(call, result: result)
    case "clearScene":
      handleClearScene(call, result: result)
    case "loadModelFromAsset":
      handleLoadModelFromAsset(call, result: result)
    case "loadModelFromUrl":
      handleLoadModelFromUrl(call, result: result)
    case "getCacheSizeBytes":
      handleCacheSize(call, result: result)
    case "clearCache":
      handleClearCache(call, result: result)
    case "setIBLFromAsset":
      handleSetIBLFromAsset(call, result: result)
    case "setSkyboxFromAsset":
      handleSetSkyboxFromAsset(call, result: result)
    case "setIBLFromUrl":
      handleSetIBLFromUrl(call, result: result)
    case "setSkyboxFromUrl":
      handleSetSkyboxFromUrl(call, result: result)
    case "frameModel":
      handleFrameModel(call, result: result)
    case "setOrbitConstraints":
      handleOrbitConstraints(call, result: result)
    case "setInertiaEnabled":
      handleInertiaEnabled(call, result: result)
    case "setInertiaParams":
      handleInertiaParams(call, result: result)
    case "setZoomLimits":
      handleZoomLimits(call, result: result)
    case "setCustomCameraEnabled":
      handleCustomCameraEnabled(call, result: result)
    case "setCustomCameraLookAt":
      handleCustomCameraLookAt(call, result: result)
    case "setCustomPerspective":
      handleCustomPerspective(call, result: result)
    case "getAnimationCount":
      handleGetAnimationCount(call, result: result)
    case "playAnimation":
      handlePlayAnimation(call, result: result)
    case "pauseAnimation":
      handlePauseAnimation(call, result: result)
    case "seekAnimation":
      handleSeekAnimation(call, result: result)
    case "setAnimationSpeed":
      handleSetAnimationSpeed(call, result: result)
    case "getAnimationDuration":
      handleGetAnimationDuration(call, result: result)
    case "setMsaa":
      handleSetMsaa(call, result: result)
    case "setDynamicResolutionEnabled":
      handleSetDynamicResolutionEnabled(call, result: result)
    case "setToneMappingFilmic":
      handleSetToneMappingFilmic(call, result: result)
    case "setShadowsEnabled":
      handleSetShadowsEnabled(call, result: result)
    case "setWireframeEnabled":
      handleSetWireframeEnabled(call, result: result)
    case "setBoundingBoxesEnabled":
      handleSetBoundingBoxesEnabled(call, result: result)
    case "setDebugLoggingEnabled":
      handleSetDebugLoggingEnabled(call, result: result)
    case "orbitStart":
      handleOrbitStart(call, result: result)
    case "orbitDelta":
      handleOrbitDelta(call, result: result)
    case "orbitEnd":
      handleOrbitEnd(call, result: result)
    case "zoomStart":
      handleZoomStart(call, result: result)
    case "zoomDelta":
      handleZoomDelta(call, result: result)
    case "zoomEnd":
      handleZoomEnd(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard
      let args = arguments as? [String: Any],
      let controllerId = args["controllerId"] as? Int
    else {
      return FlutterError(code: "filament_error", message: "Missing controllerId.", details: nil)
    }
    eventSinks[controllerId] = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    guard
      let args = arguments as? [String: Any],
      let controllerId = args["controllerId"] as? Int
    else {
      return nil
    }
    eventSinks.removeValue(forKey: controllerId)
    return nil
  }

  @objc private func appDidEnterBackground() {
    renderLoop.setPaused(true)
  }

  @objc private func appWillEnterForeground() {
    renderLoop.setPaused(false)
  }

  private func handleCreateController(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let controllerId = args["controllerId"] as? Int
    else {
      result(FlutterError(code: "filament_error", message: "Missing controllerId.", details: nil))
      return
    }
    startObservingLifecycleIfNeeded()
    if textureRegistry == nil {
      textureRegistry = registrar?.textures()
    }
    if assetLookup == nil {
      assetLookup = { [weak registrar] assetPath in
        registrar?.lookupKey(forAsset: assetPath) ?? assetPath
      }
    }
    guard let textureRegistry, let assetLookup else {
      result(FlutterError(code: "filament_error", message: "Filament plugin not ready.", details: nil))
      return
    }
    let controller = FilamentController(
      controllerId: controllerId,
      textureRegistry: textureRegistry,
      renderLoop: renderLoop,
      cacheManager: cacheManager,
      assetLookup: assetLookup
    ) { [weak self] type, message in
      self?.emitEvent(controllerId: controllerId, type: type, message: message)
    }
    controllers[controllerId] = controller
    result(nil)
  }

  private func startObservingLifecycleIfNeeded() {
    if observingLifecycle {
      return
    }
    observingLifecycle = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  private func handleDisposeController(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.dispose(result: result)
    if let args = call.arguments as? [String: Any], let controllerId = args["controllerId"] as? Int {
      controllers.removeValue(forKey: controllerId)
    }
  }

  private func handleCreateViewer(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let width = args?["width"] as? Int ?? 1
    let height = args?["height"] as? Int ?? 1
    controller.createViewer(width: width, height: height, result: result)
  }

  private func handleResize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let width = args?["width"] as? Int ?? 1
    let height = args?["height"] as? Int ?? 1
    controller.resize(width: width, height: height, result: result)
  }

  private func handleClearScene(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.clearScene(result: result)
  }

  private func handleLoadModelFromAsset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let assetPath = args["assetPath"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing assetPath.", details: nil))
      return
    }
    controller.loadModelFromAsset(assetPath: assetPath, result: result)
  }

  private func handleLoadModelFromUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let url = args["url"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing url.", details: nil))
      return
    }
    controller.loadModelFromUrl(urlString: url, result: result)
  }

  private func handleCacheSize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.getCacheSizeBytes(result: result)
  }

  private func handleClearCache(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.clearCache(result: result)
  }

  private func handleSetIBLFromAsset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let ktxPath = args["ktxPath"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing ktxPath.", details: nil))
      return
    }
    controller.setIBLFromAsset(ktxPath: ktxPath, result: result)
  }

  private func handleSetSkyboxFromAsset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let ktxPath = args["ktxPath"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing ktxPath.", details: nil))
      return
    }
    controller.setSkyboxFromAsset(ktxPath: ktxPath, result: result)
  }

  private func handleSetIBLFromUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let url = args["url"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing url.", details: nil))
      return
    }
    controller.setIBLFromUrl(urlString: url, result: result)
  }

  private func handleSetSkyboxFromUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard
      let args = call.arguments as? [String: Any],
      let url = args["url"] as? String
    else {
      result(FlutterError(code: "filament_error", message: "Missing url.", details: nil))
      return
    }
    controller.setSkyboxFromUrl(urlString: url, result: result)
  }

  private func handleFrameModel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let useWorldOrigin = args?["useWorldOrigin"] as? Bool ?? false
    controller.frameModel(useWorldOrigin: useWorldOrigin, result: result)
  }

  private func handleOrbitConstraints(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing orbit constraints.", details: nil))
      return
    }
    let minPitch = args["minPitchDeg"] as? Double ?? -89.0
    let maxPitch = args["maxPitchDeg"] as? Double ?? 89.0
    let minYaw = args["minYawDeg"] as? Double ?? -180.0
    let maxYaw = args["maxYawDeg"] as? Double ?? 180.0
    controller.setOrbitConstraints(
      minPitchDeg: minPitch,
      maxPitchDeg: maxPitch,
      minYawDeg: minYaw,
      maxYawDeg: maxYaw,
      result: result
    )
  }

  private func handleInertiaEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? true
    controller.setInertiaEnabled(enabled, result: result)
  }

  private func handleInertiaParams(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let damping = args?["damping"] as? Double ?? 0.9
    let sensitivity = args?["sensitivity"] as? Double ?? 1.0
    controller.setInertiaParams(damping: damping, sensitivity: sensitivity, result: result)
  }

  private func handleZoomLimits(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing zoom limits.", details: nil))
      return
    }
    let minDistance = args["minDistance"] as? Double ?? 0.05
    let maxDistance = args["maxDistance"] as? Double ?? 100.0
    controller.setZoomLimits(minDistance: minDistance, maxDistance: maxDistance, result: result)
  }

  private func handleCustomCameraEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? false
    controller.setCustomCameraEnabled(enabled, result: result)
  }

  private func handleCustomCameraLookAt(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing camera lookAt data.", details: nil))
      return
    }
    controller.setCustomCameraLookAt(
      eyeX: args["eyeX"] as? Double ?? 0.0,
      eyeY: args["eyeY"] as? Double ?? 0.0,
      eyeZ: args["eyeZ"] as? Double ?? 3.0,
      centerX: args["centerX"] as? Double ?? 0.0,
      centerY: args["centerY"] as? Double ?? 0.0,
      centerZ: args["centerZ"] as? Double ?? 0.0,
      upX: args["upX"] as? Double ?? 0.0,
      upY: args["upY"] as? Double ?? 1.0,
      upZ: args["upZ"] as? Double ?? 0.0,
      result: result
    )
  }

  private func handleCustomPerspective(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing perspective data.", details: nil))
      return
    }
    let fov = args["fovDegrees"] as? Double ?? 45.0
    let near = args["near"] as? Double ?? 0.05
    let far = args["far"] as? Double ?? 100.0
    controller.setCustomPerspective(fovDegrees: fov, near: near, far: far, result: result)
  }

  private func handleGetAnimationCount(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.getAnimationCount(result: result)
  }

  private func handlePlayAnimation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing animation data.", details: nil))
      return
    }
    let index = args["index"] as? Int ?? 0
    let loop = args["loop"] as? Bool ?? true
    controller.playAnimation(index: index, loop: loop, result: result)
  }

  private func handlePauseAnimation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.pauseAnimation(result: result)
  }

  private func handleSeekAnimation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let seconds = args?["seconds"] as? Double ?? 0.0
    controller.seekAnimation(seconds: seconds, result: result)
  }

  private func handleSetAnimationSpeed(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let speed = args?["speed"] as? Double ?? 1.0
    controller.setAnimationSpeed(speed: speed, result: result)
  }

  private func handleGetAnimationDuration(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let index = args?["index"] as? Int ?? 0
    controller.getAnimationDuration(index: index, result: result)
  }

  private func handleSetMsaa(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let samples = args?["samples"] as? Int ?? 2
    controller.setMsaa(samples: samples, result: result)
  }

  private func handleSetDynamicResolutionEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? true
    controller.setDynamicResolutionEnabled(enabled, result: result)
  }

  private func handleSetToneMappingFilmic(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.setToneMappingFilmic(result: result)
  }

  private func handleSetShadowsEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? true
    controller.setShadowsEnabled(enabled, result: result)
  }

  private func handleSetWireframeEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? false
    controller.setWireframeEnabled(enabled, result: result)
  }

  private func handleSetBoundingBoxesEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? false
    controller.setBoundingBoxesEnabled(enabled, result: result)
  }

  private func handleSetDebugLoggingEnabled(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    let args = call.arguments as? [String: Any]
    let enabled = args?["enabled"] as? Bool ?? false
    controller.setDebugLoggingEnabled(enabled, result: result)
  }

  private func handleOrbitStart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.orbitStart(result: result)
  }

  private func handleOrbitDelta(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing orbit delta.", details: nil))
      return
    }
    let dx = args["dx"] as? Double ?? 0.0
    let dy = args["dy"] as? Double ?? 0.0
    controller.orbitDelta(dx: dx, dy: dy, result: result)
  }

  private func handleOrbitEnd(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing orbit velocity.", details: nil))
      return
    }
    let velocityX = args["velocityX"] as? Double ?? 0.0
    let velocityY = args["velocityY"] as? Double ?? 0.0
    controller.orbitEnd(velocityX: velocityX, velocityY: velocityY, result: result)
  }

  private func handleZoomStart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.zoomStart(result: result)
  }

  private func handleZoomDelta(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "filament_error", message: "Missing zoom delta.", details: nil))
      return
    }
    let scaleDelta = args["scaleDelta"] as? Double ?? 1.0
    controller.zoomDelta(scaleDelta: scaleDelta, result: result)
  }

  private func handleZoomEnd(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = resolveController(call, result: result) else { return }
    controller.zoomEnd(result: result)
  }

  private func resolveController(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> FilamentController? {
    guard
      let args = call.arguments as? [String: Any],
      let controllerId = args["controllerId"] as? Int
    else {
      result(FlutterError(code: "filament_error", message: "Missing controllerId.", details: nil))
      return nil
    }
    guard let controller = controllers[controllerId] else {
      result(FlutterError(code: "filament_error", message: "Unknown controllerId.", details: nil))
      return nil
    }
    return controller
  }

  private func emitEvent(controllerId: Int, type: String, message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSinks[controllerId]?(["type": type, "message": message])
    }
  }
}
