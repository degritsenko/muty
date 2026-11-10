import Foundation

@testable import muty

@MainActor
func runSFTPTest(_ body: @escaping @MainActor () async throws -> Void) throws {
  var result: Result<Void, Error>?
  let task = Task { @MainActor in
    do {
      try await body()
      result = .success(())
    } catch { result = .failure(error) }
  }
  let deadline = Date().addingTimeInterval(15)
  while result == nil && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  }
  guard let result else {
    task.cancel()
    throw MutyError("SFTP test timed out")
  }
  try result.get()
}

@MainActor
final class MemoryTransferExecutor: SFTPTransferExecuting {
  var files: [String: Data] = [:]
  var failure: String?
  var planFailure = false
  var existsHook: (() async -> Void)?
  var copyHook: (() async -> Void)?
  var lastProgress: (@MainActor (SFTPProgress) -> Void)?
  var copied: [String] = []
  var pauses: [Bool] = []
  var cancels = 0
  func plan(_ request: SFTPTransferRequest) async throws -> [SFTPTransfer] {
    if planFailure { throw MutyError("Planning failed") }
    switch request {
    case .upload(let urls, let target):
      return urls.map {
        .init(kind: .upload, source: $0.path, destination: target + "/" + $0.lastPathComponent)
      }
    case .download(let files, let target):
      return files.map {
        .init(kind: .download, source: $0.path, destination: target + "/" + $0.name)
      }
    }
  }
  func destinationExists(for transfer: SFTPTransfer) async throws -> Bool {
    await existsHook?()
    return files[transfer.destination] != nil
  }
  func availableDestination(for transfer: SFTPTransfer) async throws -> String {
    var n = 1
    while files[transfer.destination + ".copy\(n)"] != nil { n += 1 }
    return transfer.destination + ".copy\(n)"
  }
  func copy(
    _ transfer: SFTPTransfer, to destination: String, replace: Bool,
    progress: @escaping @MainActor (SFTPProgress) -> Void
  ) async throws {
    lastProgress = progress
    await copyHook?()
    if transfer.source == failure { throw MutyError("Copy failed") }
    guard replace || files[destination] == nil else { throw MutyError("Destination exists") }
    files[destination] = Data(transfer.source.utf8)
    copied.append(transfer.source)
    progress(SFTPProgress(name: transfer.source, bytes: 1, total: 1))
  }
  func setPaused(_ paused: Bool) { pauses.append(paused) }
  func cancel() { cancels += 1 }
}

@MainActor
enum SFTPQueueTests {
  static func request(_ names: [String]) -> SFTPTransferRequest {
    .upload(names.map { URL(fileURLWithPath: "/source/" + $0) }, to: "/destination")
  }
  static func replace(_ transfer: SFTPTransfer) -> SFTPConflictResolution {
    .init(choice: .replace)
  }

  static func conflictsAndRetry() throws {
    try runSFTPTest {
      let queue = SFTPTransferQueue()
      let executor = MemoryTransferExecutor()
      let owner = UUID()
      queue.attach(owner: owner, executor: executor)
      executor.files["/destination/a"] = Data("original".utf8)
      executor.files["/destination/b"] = Data("original".utf8)
      var prompts = 0
      try await queue.run(
        owner: owner, request: request(["a", "b", "c"]),
        resolveConflict: { _ in
          prompts += 1
          return .init(choice: .skip, applyToAll: true)
        })
      assert(prompts == 1 && queue.items.map(\.state) == [.skipped, .skipped, .done])
      assert(executor.copied == ["/source/c"])
      try await queue.run(
        owner: owner, request: request(["a"]),
        resolveConflict: { _ in
          prompts += 1
          return .init(choice: .keepBoth)
        })
      assert(prompts == 2 && queue.items.last?.destination == "/destination/a.copy1")
      assert(executor.files["/destination/a"] == Data("original".utf8))
      try await queue.run(owner: owner, request: request(["a"]), resolveConflict: replace)
      assert(executor.files["/destination/a"] == Data("/source/a".utf8))
      executor.failure = "/source/bad"
      try await queue.run(
        owner: owner, request: request(["bad", "good"]), resolveConflict: replace)
      assert(queue.items.suffix(2).map(\.state) == [.failed, .done])
      let failed = queue.items[queue.items.count - 2].id
      executor.failure = nil
      queue.retry(owner: owner, id: failed)
      assert(queue.items[queue.items.count - 2].error == nil)
      try await queue.run(owner: owner, resolveConflict: replace)
      assert(queue.items.allSatisfy { $0.state == .done || $0.state == .skipped })
      assert(executor.copied.filter { $0 == "/source/good" }.count == 1)
      queue.clearFinished()
      assert(queue.items.isEmpty)
      executor.planFailure = true
      do {
        try await queue.run(owner: owner, request: request(["unplanned"]), resolveConflict: replace)
        assertionFailure("Planning failure was swallowed")
      } catch { assert(queue.items.isEmpty && !queue.running) }
    }
  }

  static func pauseCancelAndRetry() throws {
    try runSFTPTest {
      let queue = SFTPTransferQueue()
      let executor = MemoryTransferExecutor()
      let owner = UUID()
      queue.attach(owner: owner, executor: executor)
      var gate: CheckedContinuation<Void, Never>?
      executor.copyHook = { await withCheckedContinuation { gate = $0 } }
      let task = Task {
        try await queue.run(owner: owner, request: request(["a", "b"]), resolveConflict: replace)
      }
      while gate == nil { await Task.yield() }
      assert(queue.items.map(\.state) == [.copying, .waiting])
      queue.pause(owner: owner)
      assert(queue.paused && executor.pauses.last == true)
      queue.clearFinished()
      queue.retry(owner: owner)
      assert(queue.items.count == 2 && queue.paused)
      queue.resume(owner: owner)
      assert(!queue.paused && executor.pauses.last == false)
      queue.pause(owner: owner)
      queue.cancel(owner: owner)
      assert(!queue.paused && executor.cancels == 1 && queue.items[1].state == .cancelled)
      executor.failure = "/source/a"
      executor.copyHook = nil
      gate?.resume()
      try await task.value
      assert(queue.items.map(\.state) == [.cancelled, .cancelled])
      executor.failure = nil
      queue.retry(owner: owner)
      try await queue.run(owner: owner, resolveConflict: replace)
      assert(queue.items.map(\.state) == [.done, .done])
      assert(executor.copied == ["/source/a", "/source/b"])
      // Cancelling from a modal prompt must prevent the next filesystem call.
      try await queue.run(
        owner: owner, request: request(["a", "b"]), resolveConflict: { _ in .init(choice: .cancel) }
      )
      assert(queue.items.suffix(2).map(\.state) == [.cancelled, .cancelled])
      assert(executor.copied.count == 2)
    }
  }

  static func ownerReplacement() throws {
    try runSFTPTest {
      let queue = SFTPTransferQueue()
      let old = MemoryTransferExecutor()
      let new = MemoryTransferExecutor()
      let oldOwner = UUID()
      let newOwner = UUID()
      queue.attach(owner: oldOwner, executor: old)
      var gate: CheckedContinuation<Void, Never>?
      old.copyHook = { await withCheckedContinuation { gate = $0 } }
      var oldProgress = 0
      let task = Task {
        try await queue.run(
          owner: oldOwner, request: request(["a", "b"]), resolveConflict: replace,
          progress: { _ in oldProgress += 1 })
      }
      while gate == nil { await Task.yield() }
      queue.attach(owner: newOwner, executor: new)
      assert(old.cancels == 1 && queue.items.map(\.state) == [.cancelled, .waiting])
      queue.cancel(owner: oldOwner)
      queue.pause(owner: oldOwner)
      queue.detach(owner: oldOwner)
      try await queue.run(owner: newOwner, resolveConflict: replace)
      gate?.resume()
      try await task.value
      old.lastProgress?(SFTPProgress(name: "stale", bytes: 1, total: 1))
      assert(oldProgress == 0 && queue.items.map(\.state) == [.cancelled, .done])
      assert(new.copied == ["/source/b"])
      // Replacing an owner during the conflict probe must not open a stale dialog.
      queue.clearFinished()
      queue.attach(owner: oldOwner, executor: old)
      old.copyHook = nil
      old.existsHook = { queue.attach(owner: newOwner, executor: new) }
      try await queue.run(
        owner: oldOwner, request: request(["a"]),
        resolveConflict: { _ in
          assertionFailure("Stale owner displayed conflict prompt")
          return .init(choice: .replace)
        })
      assert(queue.items.first?.state == .cancelled)
    }
  }
}
