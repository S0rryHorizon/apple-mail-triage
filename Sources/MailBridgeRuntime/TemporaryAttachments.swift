import Foundation
import MailBridgeCore

enum TemporaryAttachments {
  static var root: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MailTriage", isDirectory: true)
  }

  static func remove(_ path: String, root: URL = root) throws {
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let parent = root.standardizedFileURL
    guard candidate.deletingLastPathComponent() == parent,
      UUID(uuidString: candidate.lastPathComponent) != nil,
      candidate.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath()
    else { throw MailBridgeError.attachmentRejected("拒绝清理受管临时附件目录以外的路径。") }
    if FileManager.default.fileExists(atPath: candidate.path) {
      try FileManager.default.removeItem(at: candidate)
    }
  }

  // No daemon: recover exports abandoned by a killed process on the next bridge call.
  static func sweep(store: StateStore, root: URL = root, now: Date = Date()) throws {
    let cutoff = now.addingTimeInterval(-24 * 60 * 60)
    for (token, path) in try store.expiredExports(before: cutoff) {
      try remove(path, root: root)
      try store.removeExport(token: token)
    }
    // Also recover a crash between directory creation and token registration.
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) {
      let values = try directory.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
      if values.isDirectory == true, values.isSymbolicLink != true,
        UUID(uuidString: directory.lastPathComponent) != nil,
        let created = values.creationDate, created < cutoff {
        try remove(directory.path, root: root)
      }
    }
  }
}
