import Foundation
import QuartzCore

final class FilamentRenderLoop: NSObject {
  static let shared = FilamentRenderLoop()

  private var thread: Thread
  private let lock = NSLock()
  private var tasks: [() -> Void] = []
  private var renderers = NSHashTable<FilamentRenderer>.weakObjects()
  private var paused = false

  private override init() {
    thread = Thread()
    super.init()
    thread = Thread(target: self, selector: #selector(threadEntryPoint), object: nil)
    thread.name = "FilamentRenderThread"
    thread.start()
  }

  func perform(_ block: @escaping () -> Void) {
    lock.lock()
    tasks.append(block)
    lock.unlock()
    perform(#selector(processTasks), on: thread, with: nil, waitUntilDone: false)
  }

  func addRenderer(_ renderer: FilamentRenderer) {
    perform { [weak self] in
      self?.renderers.add(renderer)
    }
  }

  func removeRenderer(_ renderer: FilamentRenderer) {
    perform { [weak self] in
      self?.renderers.remove(renderer)
    }
  }

  func setPaused(_ paused: Bool) {
    perform { [weak self] in
      guard let self else { return }
      self.paused = paused
      for renderer in self.renderers.allObjects {
        renderer.setPaused(paused)
      }
    }
  }

  @objc private func threadEntryPoint() {
    autoreleasepool {
      let displayLink = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
      displayLink.preferredFramesPerSecond = 60
      displayLink.add(to: .current, forMode: .default)
      RunLoop.current.run()
    }
  }

  @objc private func processTasks() {
    drainTasks()
  }

  @objc private func onDisplayLink(_ link: CADisplayLink) {
    drainTasks()
    if paused {
      return
    }
    let frameTimeNanos = UInt64(link.timestamp * 1_000_000_000)
    for renderer in renderers.allObjects {
      renderer.renderFrame(frameTimeNanos)
    }
  }

  private func drainTasks() {
    lock.lock()
    let pending = tasks
    tasks.removeAll()
    lock.unlock()
    for task in pending {
      task()
    }
  }
}
