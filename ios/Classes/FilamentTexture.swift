import Flutter
import Foundation
import CoreVideo

final class FilamentTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var pixelBuffer: CVPixelBuffer?

  init(pixelBuffer: CVPixelBuffer?) {
    self.pixelBuffer = pixelBuffer
  }

  func updatePixelBuffer(_ buffer: CVPixelBuffer?) {
    lock.lock()
    pixelBuffer = buffer
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    guard let buffer = pixelBuffer else {
      lock.unlock()
      return nil
    }
    lock.unlock()
    return Unmanaged.passRetained(buffer)
  }
}
