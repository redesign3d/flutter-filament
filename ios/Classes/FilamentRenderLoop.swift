import Foundation
import QuartzCore

final class FilamentRenderLoop: NSObject {
  static let shared = FilamentRenderLoop()

  private var thread: Thread
  private let lock = NSLock()
  private var tasks: [() -> Void] = []
  private var renderers = NSHashTable<FilamentRenderer>.weakObjects()
  
  // State tracking
  private var isAppPaused = false
  private var displayLink: CADisplayLink?

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
      guard let self = self else { return }
      self.renderers.add(renderer)
      self.updateLoopState()
    }
  }

  func removeRenderer(_ renderer: FilamentRenderer) {
    perform { [weak self] in
      guard let self = self else { return }
      self.renderers.remove(renderer)
      self.updateLoopState()
    }
  }

  func setAppPaused(_ paused: Bool) {
    perform { [weak self] in
      guard let self = self else { return }
      if self.isAppPaused != paused {
        self.isAppPaused = paused
        // Propagate to renderers if needed (e.g. to release resources?)
        // For now, we just stop the loop.
        for renderer in self.renderers.allObjects {
          renderer.setPaused(paused)
        }
        self.updateLoopState()
        
        let stateName = paused ? "paused" : "resumed"
        NSLog("[FilamentRenderLoop] App lifecycle state: \(stateName)")
      }
    }
  }
  
  // Legacy alias
  func setPaused(_ paused: Bool) {
    setAppPaused(paused)
  }

  @objc private func threadEntryPoint() {
    autoreleasepool {
      let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
      link.preferredFramesPerSecond = 60
      link.add(to: .current, forMode: .default)
      self.displayLink = link
      
      // Initial state check
      updateLoopState()
      
      RunLoop.current.run()
    }
  }
  
  private func updateLoopState() {
     // We pause if app is explicitly paused OR if we have no renderers to draw
     // (Using .allObjects.isEmpty because weakObjects might have cleared)
     let shouldPause = isAppPaused || renderers.allObjects.isEmpty
     
     if let link = displayLink, link.isPaused != shouldPause {
         link.isPaused = shouldPause
         NSLog("[FilamentRenderLoop] DisplayLink isPaused = \(shouldPause) (appPaused=\(isAppPaused), renderers=\(renderers.allObjects.count))")
     }
  }

  @objc private func processTasks() {
    drainTasks()
  }

  @objc private func onDisplayLink(_ link: CADisplayLink) {
    drainTasks()
    // Double check just in case
    if isAppPaused {
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
