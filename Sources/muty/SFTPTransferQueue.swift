import Combine
import Foundation

struct SFTPProgress {
  let name: String
  let bytes: UInt64
  let total: UInt64?
}

struct SFTPTransfer: Codable, Identifiable {
  enum Kind: String, Codable { case upload, download, uploadDirectory, downloadDirectory }
  enum State: String, Codable {
    case waiting = "Waiting"
    case copying = "Copying"
    case interrupted = "Interrupted"
    case done = "Done"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case skipped = "Skipped"
  }
  var id = UUID()
  let kind: Kind
  let source: String
  var destination: String
  var state: State = .waiting
  var error: String?
  var isUpload: Bool { kind == .upload || kind == .uploadDirectory }
  var isDirectory: Bool { kind == .uploadDirectory || kind == .downloadDirectory }
  var canRetry: Bool { state == .failed || state == .cancelled || state == .interrupted }
  var isFinished: Bool { state != .waiting && state != .copying && state != .interrupted }
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
  @Published private(set) var awaitingStart = false
  @Published private(set) var persistenceError: String?
  let recoveryStore: SFTPTransferQueueStore?
  private let save: (([SFTPTransfer], [UUID]) throws -> Void)?
  private var pendingRemovals = Set<UUID>()

  init(recoveryStore: SFTPTransferQueueStore? = nil, loadError: Error? = nil,
       save: (([SFTPTransfer], [UUID]) throws -> Void)? = nil) {
    self.recoveryStore = recoveryStore
    self.save = save
    persistenceError = loadError.map { "Could not restore the transfer queue: " + $0.localizedDescription }
  }

  func restore(owner: UUID) {
    guard self.owner == owner, operation == nil, let recoveryStore else { return }
    let restored = recoveryStore.takeRecovered().map { item in
      var item = item
      if item.state == .copying { item.state = .interrupted }
      return item
    }
    guard !restored.isEmpty else { return }
    items.append(contentsOf: restored)
    if restored.contains(where: { $0.state == .waiting || $0.state == .interrupted }) {
      awaitingStart = true
    }
  }

  private func saveItems(_ updated: [SFTPTransfer] = [], removing removed: [UUID] = []) {
    guard let save, !updated.isEmpty || !removed.isEmpty else { return }
    pendingRemovals.formUnion(removed)
    do {
      // Reconcile the current queue if a previous write failed.
      try save(persistenceError == nil ? updated : items, Array(pendingRemovals))
      pendingRemovals.removeAll()
      persistenceError = nil
    } catch {
      persistenceError = "Could not save the transfer queue: " + error.localizedDescription
    }
  }

  func start(owner: UUID) {
    guard self.owner == owner, operation == nil else { return }
    awaitingStart = false
  }
  @Published private(set) var paused = false
  @Published private(set) var running = false
  var localPath: String?
  var remotePath: String?
  private var owner: UUID?
  private var executor: (any SFTPTransferExecuting)?
  private var operation: UUID?
  private var isolatedTransfer: UUID?
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
    isolatedTransfer = nil
    running = false
    if save != nil && (hasPending || items.contains(where: { $0.state == .copying })) {
      awaitingStart = true
      paused = false
    }
    let copying = items.indices.filter { items[$0].state == .copying }
    for index in copying { items[index].state = save == nil ? .cancelled : .interrupted }
    saveItems(copying.map { items[$0] })
    self.owner = nil
    executor = nil
    if let recoveryStore, persistenceError == nil, items.contains(where: { !$0.isFinished || $0.canRetry }) {
      recoveryStore.returnForRecovery(items)
      items.removeAll()
      awaitingStart = false
      paused = false
    }
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
    if running && isolatedTransfer == nil {
      let waiting = items.indices.filter { items[$0].state == .waiting }
      for index in waiting { items[index].state = .cancelled }
      saveItems(waiting.map { items[$0] })
    }
    executor?.cancel()
  }

  func retry(owner: UUID, id: UUID? = nil) {
    guard self.owner == owner, operation == nil else { return }
    let retrying = items.indices.filter { index in
      let item = items[index]
      return item.canRetry && (item.id == id || (id == nil && item.state != .interrupted))
    }
    for index in retrying {
      items[index].state = .waiting
      items[index].error = nil
    }
    saveItems(retrying.map { items[$0] })
    resume(owner: owner)
  }

  func clearFinished() {
    guard operation == nil else { return }
    let finished = items.filter(\.isFinished).map(\.id)
    items.removeAll { $0.isFinished }
    saveItems(removing: finished)
  }

  // A run retains its adapter, but only its current owner may publish results.
  // Reconnect can replace the owner while an old asynchronous call is returning.
  func run(
    owner: UUID, request: SFTPTransferRequest? = nil, only transferID: UUID? = nil,
    resolveConflict: (SFTPTransfer) -> SFTPConflictResolution,
    progress: @escaping @MainActor (SFTPProgress) -> Void = { _ in },
    status: (String) -> Void = { _ in }
  ) async throws {
    guard self.owner == owner, operation == nil, let executor else { return }
    let token = UUID()
    operation = token
    isolatedTransfer = transferID
    cancelled = false
    defer {
      if operation == token {
        operation = nil
        isolatedTransfer = nil
        running = false
        if awaitingStart && !items.contains(where: { $0.state == .waiting || $0.state == .interrupted }) {
          awaitingStart = false
        }
      }
    }
    if let request {
      let planned = try await executor.plan(request)
      try check(token)
      items.append(contentsOf: planned)
      saveItems(planned)
    }
    guard !paused, !awaitingStart || transferID != nil else { return }
    running = true
    var allChoice: SFTPConflictResolution.Choice?
    while operation == token, !cancelled, !Task.isCancelled, !paused,
      let index = items.firstIndex(where: { $0.state == .waiting && (transferID == nil || $0.id == transferID) })
    {
      let transfer = items[index]
      items[index].state = .copying
      saveItems([items[index]])
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
          saveItems([items[index]])
          continue
        }
        let target: String
        if choice == .keepBoth {
          target = try await executor.availableDestination(for: transfer)
        } else {
          target = transfer.destination
        }
        try check(token)
        if target != transfer.destination {
          items[index].destination = target
          saveItems([items[index]])
        }
        try await executor.copy(transfer, to: target, replace: exists && choice == .replace) {
          [weak self] value in
          guard let self, self.operation == token, !self.cancelled else { return }
          progress(value)
        }
        // A completed atomic copy stays done even if cancel arrived just after commit.
        guard operation == token else { break }
        items[index].state = .done
      } catch {
        guard operation == token else { break }
        items[index].state =
          error is CancellationError || cancelled || Task.isCancelled ? .cancelled : .failed
        items[index].error = error.localizedDescription
      }
      saveItems([items[index]])
    }
  }

  private func check(_ token: UUID) throws {
    guard operation == token, !cancelled else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
