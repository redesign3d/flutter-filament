import Flutter
import UIKit

public class FilamentWidgetPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textureRegistry: FlutterTextureRegistry
  private let assetLookup: (String) -> String
  private let renderLoop = FilamentRenderLoop.shared
  private let cacheManager = FilamentCacheManager()
  private var controllers: [Int: FilamentController] = [:]
  private var eventSinks: [Int: FlutterEventSink] = [:]

  init(
    textureRegistry: FlutterTextureRegistry,
    assetLookup: @escaping (String) -> String
  ) {
    self.textureRegistry = textureRegistry
    self.assetLookup = assetLookup
    super.init()
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

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "filament_widget", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "filament_widget/events", binaryMessenger: registrar.messenger())
    let instance = FilamentWidgetPlugin(
      textureRegistry: registrar.textures(),
      assetLookup: registrar.lookupKey(forAsset:)
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
    eventChannel.setStreamHandler(instance)
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
