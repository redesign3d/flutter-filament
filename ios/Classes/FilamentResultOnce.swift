import Flutter
import Foundation

final class FilamentResultOnce {
  private let lock = NSLock()
  private var completed = false
  private let result: FlutterResult

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func success(_ value: Any?) {
    completeOnce { self.result(value) }
  }

  func error(code: String, message: String) {
    completeOnce {
      self.result(FlutterError(code: code, message: message, details: nil))
    }
  }

  func notImplemented() {
    completeOnce { self.result(FlutterMethodNotImplemented) }
  }

  private func completeOnce(_ block: @escaping () -> Void) {
    lock.lock()
    if completed {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    DispatchQueue.main.async(execute: block)
  }
}
