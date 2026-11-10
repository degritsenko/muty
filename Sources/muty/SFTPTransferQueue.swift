import Combine
import Foundation

struct SFTPProgress {
  let name: String
  let bytes: UInt64
  let total: UInt64?
}

struct SFTPTransfer: Identifiable {
  enum Kind { case upload, download, uploadDirectory, downloadDirectory }
  enum State: String {
    case waiting = "Waiting"
    case copying = "Copying"
    case done = "Done"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case skipped = "Skipped"
  }
  let id = UUID()
  let kind: Kind
  let source: String
  var destination: String
  var state: State = .waiting
  var error: String?
  var isUpload: Bool { kind == .upload || kind == .uploadDirectory }
  var isDirectory: Bool { kind == .uploadDirectory || kind == .downloadDirectory }
  var canRetry: Bool { state == .failed || state == .cancelled }
  var isFinished: Bool { state != .waiting && state != .copying }
}

enum SFTPTransferRequest {
  case upload([URL], to: String)
  case download([BrowserFile], to: String)
}

struct SFTPConflictResolution {
  enum Choice { case replace, skip, keepBoth, cancel }
  let choice: Choice
  var applyToAll = false
}

@MainActor
protocol SFTPTransferExecuting: AnyObject {
  func plan(_ request: SFTPTransferRequest) async throws -> [SFTPTransfer]
  func destinationExists(for transfer: SFTPTransfer) async throws -> Bool
  func availableDestination(for transfer: SFTPTransfer) async throws -> String
  func copy(
    _ transfer: SFTPTransfer, to destination: String, replace: Bool,
    progress: @escaping @MainActor (SFTPProgress) -> Void) async throws
  func setPaused(_ paused: Bool)
  func cancel()
}

@MainActor
final class SFTPTransferQueue: ObservableObject {
  @Published private(set) var items: [SFTPTransfer] = []
  @Published private(set) var paused = false
  @Published private(set) var running = false
  var localPath: String?
  var remotePath: String?
  private var owner: UUID?
  private var executor: (any SFTPTransferExecuting)?
  private var operation: UUID?
  private var cancelled = false

  var hasPending: Bool { items.contains { $0.state == .waiting } }

  func attach(owner: UUID, executor: any SFTPTransferExecuting) {
    if let previous = self.owner { detach(owner: previous) }
    self.owner = owner
    self.executor = executor
  }

  func detach(owner: UUID) {
    guard self.owner == owner else { return }
    executor?.cancel()
    operation = nil
    running = false
    for index in items.indices where items[index].state == .copying {
      items[index].state = .cancelled
    }
    self.owner = nil
    executor = nil
  }

  func pause(owner: UUID) {
    guard self.owner == owner, running else { return }
    paused = true
    executor?.setPaused(true)
  }

  func resume(owner: UUID) {
    guard self.owner == owner else { return }
    paused = false
    executor?.setPaused(false)
  }

  func cancel(owner: UUID) {
    guard self.owner == owner, operation != nil else { return }
    cancelled = true
    paused = false
    if running {
      for index in items.indices where items[index].state == .waiting {
        items[index].state = .cancelled
      }
    }
    executor?.cancel()
  }

  func retry(owner: UUID, id: UUID? = nil) {
    guard self.owner == owner, operation == nil else { return }
    for index in items.indices where (id == nil || items[index].id == id) && items[index].canRetry {
      items[index].state = .waiting
      items[index].error = nil
    }
    resume(owner: owner)
  }

  func clearFinished() {
    guard operation == nil else { return }
    items.removeAll { $0.isFinished }
  }

  // A run retains its adapter, but only its current owner may publish results.
  // Reconnect can replace the owner while an old asynchronous call is returning.
  func run(
    owner: UUID, request: SFTPTransferRequest? = nil,
    resolveConflict: (SFTPTransfer) -> SFTPConflictResolution,
    progress: @escaping @MainActor (SFTPProgress) -> Void = { _ in },
    status: (String) -> Void = { _ in }
  ) async throws {
    guard self.owner == owner, operation == nil, let executor else { return }
    let token = UUID()
    operation = token
    cancelled = false
    defer {
      if operation == token {
        operation = nil
        running = false
      }
    }
    if let request {
      let planned = try await executor.plan(request)
      try check(token)
      items.append(contentsOf: planned)
    }
    guard !paused else { return }
    running = true
    var allChoice: SFTPConflictResolution.Choice?
    while operation == token, !cancelled, !Task.isCancelled, !paused,
      let index = items.firstIndex(where: { $0.state == .waiting })
    {
      let transfer = items[index]
      items[index].state = .copying
      status("Copying " + (transfer.source as NSString).lastPathComponent)
      do {
        let exists = try await executor.destinationExists(for: transfer)
        try check(token)
        var choice = SFTPConflictResolution.Choice.replace
        if exists && !transfer.isDirectory {
          if let allChoice {
            choice = allChoice
          } else {
            let resolution = resolveConflict(transfer)
            choice = resolution.choice
            if resolution.applyToAll { allChoice = choice }
          }
        }
        // Modal conflict prompts can process disconnect/cancel events.
        try check(token)
        if choice == .cancel {
          cancel(owner: owner)
          throw CancellationError()
        }
        if choice == .skip {
          items[index].state = .skipped
          continue
        }
        let target: String
        if choice == .keepBoth {
          target = try await executor.availableDestination(for: transfer)
        } else {
          target = transfer.destination
        }
        try check(token)
        try await executor.copy(transfer, to: target, replace: exists && choice == .replace) {
          [weak self] value in
          guard let self, self.operation == token, !self.cancelled else { return }
          progress(value)
        }
        // A completed atomic copy stays done even if cancel arrived just after commit.
        guard operation == token else { break }
        items[index].destination = target
        items[index].state = .done
      } catch {
        guard operation == token else { break }
        items[index].state =
          error is CancellationError || cancelled || Task.isCancelled ? .cancelled : .failed
        items[index].error = error.localizedDescription
      }
    }
  }

  private func check(_ token: UUID) throws {
    guard operation == token, !cancelled else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
