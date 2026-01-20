import Foundation
import CryptoKit

final class FilamentCacheManager {
  private let cacheDir: URL

  init() {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDir = base.appendingPathComponent("filament_widget_cache", isDirectory: true)
  }

  func getCacheSizeBytes() -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        total += Int64(size)
      }
    }
    return total
  }

  func clearCache() -> Bool {
    if FileManager.default.fileExists(atPath: cacheDir.path) {
      do {
        try FileManager.default.removeItem(at: cacheDir)
      } catch {
        return false
      }
    }
    return true
  }

  func getOrDownload(url: URL) throws -> URL {
    try ensureCacheDir()
    let target = cacheDir.appendingPathComponent(cacheFileName(for: url))
    if FileManager.default.fileExists(atPath: target.path) {
      return target
    }
    let data = try Data(contentsOf: url)
    try data.write(to: target, options: .atomic)
    return target
  }

  func getOrDownload(url: URL, cacheRoot: URL, relativePath: String) throws -> URL {
    try ensureCacheDir()
    try ensureDirectory(cacheRoot)
    let safePath = sanitizeRelativePath(relativePath)
    let target = cacheRoot.appendingPathComponent(safePath)
    try ensureDirectory(target.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: target.path) {
      return target
    }
    let data = try Data(contentsOf: url)
    try data.write(to: target, options: .atomic)
    return target
  }

  func modelCacheDirectory(for url: URL) throws -> URL {
    try ensureCacheDir()
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    let dir = cacheDir.appendingPathComponent(hash, isDirectory: true)
    try ensureDirectory(dir)
    return dir
  }

  private func cacheFileName(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    let ext = url.pathExtension
    return ext.isEmpty ? hash : "\(hash).\(ext)"
  }

  private func ensureCacheDir() throws {
    try ensureDirectory(cacheDir)
  }

  private func ensureDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  private func sanitizeRelativePath(_ path: String) -> String {
    let cleaned = path.replacingOccurrences(of: "\\", with: "/")
    if cleaned.isEmpty {
      return "resource.bin"
    }
    if cleaned.contains("..") || cleaned.hasPrefix("/") {
      return URL(fileURLWithPath: cleaned).lastPathComponent
    }
    return cleaned
  }
}
