#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider snapshot publication")
  struct WindowsProviderSnapshotPublisherTests {
    @Test("credential mutation during a delayed sibling rejects the stale provider at commit")
    func delayedBatchRejectsStaleProvider() async throws {
      let provider = WindowsProviderID.windsurf
      let revision = LockedRevision("revision-before-fetch")
      let siblingStarted = SnapshotLockedFlag()
      let releaseSibling = SnapshotLockedFlag()
      let staleSnapshot = WindowsProviderSnapshot(
        provider: provider,
        availability: .available,
        usedPercent: 10,
        sourceText: "Manual · WSL CLI · Ubuntu",
        publicationAuthorityCheck: {
          revision.value == "revision-before-fetch"
        })
      let batch = Task.detached {
        siblingStarted.set()
        try await waitForSnapshotPublisherCondition(timeout: .seconds(5)) { releaseSibling.value }
        return [
          staleSnapshot,
          WindowsProviderSnapshot(
            provider: .cursor,
            availability: .available,
            usedPercent: 20,
            sourceText: "Automatic · WSL CLI · Ubuntu"),
        ]
      }

      defer { releaseSibling.set() }
      try await waitForSnapshotPublisherCondition(timeout: .seconds(2)) { siblingStarted.value }
      try WindowsProviderOperationLock.withLock(provider: provider) {
        revision.set("revision-saved-by-other-process")
      }
      releaseSibling.set()

      let committed = LockedProviders()
      let outcome = WindowsProviderSnapshotPublisher.publish(try await batch.value) { snapshot in
        committed.append(snapshot.provider)
      }
      #expect(outcome.rejectedProviders == [provider])
      #expect(outcome.requiresRefresh)
      #expect(committed.value == [.cursor])
    }

    @Test("publication rejects provider mutex contention without blocking the UI thread")
    func contentionRejectsImmediately() async throws {
      let provider = WindowsProviderID.zed
      let holderEntered = SnapshotLockedFlag()
      let releaseHolder = DispatchSemaphore(value: 0)
      let holder = Task {
        try await runSnapshotPublisherHolder {
          try WindowsProviderOperationLock.withLock(provider: provider) {
            holderEntered.set()
            guard releaseHolder.wait(timeout: .now() + 5) == .success else {
              throw SnapshotPublisherTestError.timedOut
            }
          }
        }
      }
      defer { releaseHolder.signal() }
      try await waitForSnapshotPublisherCondition(timeout: .seconds(2)) { holderEntered.value }

      let committed = LockedProviders()
      let clock = ContinuousClock()
      let started = clock.now
      let outcome = WindowsProviderSnapshotPublisher.publish([
        WindowsProviderSnapshot(
          provider: provider,
          availability: .available,
          sourceText: "Manual · WSL CLI · Ubuntu")
      ]) { snapshot in
        committed.append(snapshot.provider)
      }
      let elapsed = started.duration(to: clock.now)

      #expect(elapsed < .seconds(1))
      #expect(outcome.rejectedProviders == [provider])
      #expect(outcome.requiresRefresh)
      #expect(committed.value.isEmpty)
      releaseHolder.signal()
      try await holder.value
    }
  }

  private enum SnapshotPublisherTestError: Error {
    case timedOut
  }

  private func runSnapshotPublisherHolder(
    _ operation: @escaping @Sendable () throws -> Void
  ) async throws {
    let queue = DispatchQueue(label: "CodexBarTests.ProviderSnapshotPublisher")
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          try operation()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func waitForSnapshotPublisherCondition(
    timeout: Duration,
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw SnapshotPublisherTestError.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private final class LockedRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) {
      self.storedValue = value
    }

    var value: String {
      self.lock.withLock { self.storedValue }
    }

    func set(_ value: String) {
      self.lock.withLock { self.storedValue = value }
    }
  }

  private final class LockedProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [WindowsProviderID] = []

    var value: [WindowsProviderID] {
      self.lock.withLock { self.providers }
    }

    func append(_ provider: WindowsProviderID) {
      self.lock.withLock { self.providers.append(provider) }
    }
  }

  private final class SnapshotLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
      self.lock.withLock { self.storedValue }
    }

    func set() {
      self.lock.withLock { self.storedValue = true }
    }
  }
#endif
