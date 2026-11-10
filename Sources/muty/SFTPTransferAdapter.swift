import Foundation

@MainActor
final class SFTPTransferAdapter: SFTPTransferExecuting {
  private let client: SFTPClient
  init(client: SFTPClient) { self.client = client }
  func setPaused(_ paused: Bool) { client.setPaused(paused) }
  func cancel() { client.cancel() }

  func plan(_ request: SFTPTransferRequest) async throws -> [SFTPTransfer] {
    try await client.perform { client in
      switch request {
      case .upload(let files, let target):
        var jobs: [SFTPTransfer] = []
        func visit(_ source: URL, _ destination: String, _ depth: Int) throws {
          try client.checkCancellation()
          guard depth < 64, jobs.count < 100000 else {
            throw MutyError("Transfer is too large or deeply nested.")
          }
          let a = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ])
          guard a.isSymbolicLink != true else { throw MutyError("Symbolic links are not copied.") }
          if a.isDirectory == true {
            jobs.append(
              .init(
                kind: .uploadDirectory, source: source.resolvingSymlinksInPath().path,
                destination: destination))
            for child in try FileManager.default.contentsOfDirectory(
              at: source, includingPropertiesForKeys: nil)
            {
              try visit(
                child, try BrowserFile.join(destination, child.lastPathComponent), depth + 1)
            }
          } else {
            guard a.isRegularFile == true else {
              throw MutyError("Only regular files can be copied.")
            }
            jobs.append(
              .init(
                kind: .upload, source: source.resolvingSymlinksInPath().path,
                destination: destination))
          }
        }
        for file in files {
          try visit(file, try BrowserFile.join(target, file.lastPathComponent), 0)
        }
        return jobs
      case .download(let files, let target):
        var jobs: [SFTPTransfer] = []
        func visit(_ source: String, _ destination: String, _ depth: Int) throws {
          guard depth < 64, jobs.count < 100000, let a = try client.attributes(source), !a.isSymlink
          else { throw MutyError("Unsupported file, symbolic link, or excessive nesting.") }
          if a.isDirectory {
            let canonical = try client.canonical(source)
            guard canonical == source else {
              throw MutyError("Directory changed or is a symbolic link.")
            }
            jobs.append(.init(kind: .downloadDirectory, source: source, destination: destination))
            for child in try client.list(source) {
              try visit(child.path, try BrowserFile.join(destination, child.name), depth + 1)
            }
            guard try client.canonical(source) == canonical else {
              throw MutyError("Directory changed while preparing transfer.")
            }
          } else {
            jobs.append(.init(kind: .download, source: source, destination: destination))
          }
        }
        for file in files { try visit(file.path, try BrowserFile.join(target, file.name), 0) }
        return jobs
      }
    }
  }
  func destinationExists(for transfer: SFTPTransfer) async throws -> Bool {
    try await client.perform { client in
      let upload = transfer.isUpload
      let directory = transfer.isDirectory
      if upload {
        guard let a = try client.attributes(transfer.destination) else { return false }
        guard !a.isSymlink, a.isDirectory == directory else {
          throw MutyError("Destination has a different type or is a symbolic link.")
        }
        return true
      }
      let url = URL(fileURLWithPath: transfer.destination)
      guard FileManager.default.fileExists(atPath: url.path) else { return false }
      let a = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard a.isSymbolicLink != true, (a.isDirectory == true) == directory else {
        throw MutyError("Destination has a different type or is a symbolic link.")
      }
      return true
    }
  }
  func availableDestination(for transfer: SFTPTransfer) async throws -> String {
    try await client.perform { client in
      let upload = transfer.isUpload
      let path = transfer.destination as NSString
      let ext = path.pathExtension
      let base = ext.isEmpty ? transfer.destination : path.deletingPathExtension
      var n = 1
      while true {
        try client.checkCancellation()
        let candidate = base + " Copy " + String(n) + (ext.isEmpty ? "" : "." + ext)
        let exists =
          upload
          ? try client.attributes(candidate) != nil
          : FileManager.default.fileExists(atPath: candidate)
        if !exists { return candidate }
        n += 1
      }
    }
  }
  func copy(
    _ transfer: SFTPTransfer, to target: String, replace: Bool,
    progress: @escaping @MainActor (SFTPProgress) -> Void
  ) async throws {
    let sink = SFTPProgressSink(publish: progress)
    let report: (String, UInt64, UInt64?) -> Void = { sink.update(name: $0, bytes: $1, total: $2) }
    try await client.perform { client in
      let upload = transfer.isUpload
      if upload {
        guard
          URL(fileURLWithPath: transfer.source).resolvingSymlinksInPath().path == transfer.source
        else { throw MutyError("Source path changed to a symbolic link.") }
        try client.validateDirectoryAncestors(target)
      } else {
        try client.validateDirectoryAncestors(transfer.source)
        let parent = URL(fileURLWithPath: (target as NSString).deletingLastPathComponent)
        guard parent.resolvingSymlinksInPath().path == parent.path else {
          throw MutyError("Destination path changed to a symbolic link.")
        }
      }
      switch transfer.kind {
      case .upload:
        try client.upload(
          URL(fileURLWithPath: transfer.source), to: target, replace: replace, progress: report)
      case .download:
        try client.download(
          transfer.source, to: URL(fileURLWithPath: target), replace: replace, progress: report)
      case .uploadDirectory:
        if let attributes = try client.attributes(target) {
          guard attributes.isDirectory, !attributes.isSymlink else {
            throw MutyError("Destination changed or became a symbolic link.")
          }
        } else {
          try client.mkdir(target)
        }
      case .downloadDirectory:
        let url = URL(fileURLWithPath: target)
        if FileManager.default.fileExists(atPath: target) {
          let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
            throw MutyError("Destination changed or became a symbolic link.")
          }
        } else {
          try FileManager.default.createDirectory(
            atPath: target, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        }
      }
    }
  }
}

// Called on the protocol queue; throttle UI publication for large transfers.
private final class SFTPProgressSink: @unchecked Sendable {
  private var last = Date.distantPast
  private let publish: @MainActor (SFTPProgress) -> Void
  init(publish: @escaping @MainActor (SFTPProgress) -> Void) { self.publish = publish }
  func update(name: String, bytes: UInt64, total: UInt64?) {
    guard bytes == 0 || bytes == total || Date().timeIntervalSince(last) >= 0.05 else { return }
    last = Date()
    DispatchQueue.main.async { [publish] in
      publish(SFTPProgress(name: name, bytes: bytes, total: total))
    }
  }
}
