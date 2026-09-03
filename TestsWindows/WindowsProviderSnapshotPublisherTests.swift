#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider snapshot publication")
  struct WindowsProviderSnapshotPublisherTests {
    @Test("credential mutation during a delayed sibling rejects the stale provider at commit")
    func delayedBatchRejectsStaleProvider() async throws {
      let revision = LockedRevision("revision-before-fetch")
      let siblingStarted = DispatchSemaphore(value: 0)
      let releaseSibling = DispatchSemaphore(value: 0)
      let staleSnapshot = WindowsProviderSnapshot(
        provider: .poe,
        availability: .available,
        usedPercent: 10,
        sourceText: "Manual · WSL CLI · Ubuntu",
        publicationAuthorityCheck: {
          revision.value == "revision-before-fetch"
        })
      let batch = Task.detached {
        siblingStarted.signal()
        _ = releaseSibling.wait(timeout: .now() + 5)
        return [
          staleSnapshot,
          WindowsProviderSnapshot(
            provider: .cursor,
            availability: .available,
            usedPercent: 20,
            sourceText: "Automatic · WSL CLI · Ubuntu"),
        ]
      }

      #expect(siblingStarted.wait(timeout: .now() + 2) == .success)
      try WindowsProviderOperationLock.withLock(provider: .poe) {
        revision.set("revision-saved-by-other-process")
      }
      releaseSibling.signal()

      let committed = LockedProviders()
      let outcome = WindowsProviderSnapshotPublisher.publish(await batch.value) { snapshot in
        committed.append(snapshot.provider)
      }
      #expect(outcome.rejectedProviders == [.poe])
      #expect(outcome.requiresRefresh)
      #expect(committed.value == [.cursor])
    }

    @Test("publication rejects provider mutex contention without blocking the UI thread")
    func contentionRejectsImmediately() async throws {
      let holderEntered = DispatchSemaphore(value: 0)
      let releaseHolder = DispatchSemaphore(value: 0)
      let holder = Task.detached {
        try WindowsProviderOperationLock.withLock(provider: .poe) {
          holderEntered.signal()
          _ = releaseHolder.wait(timeout: .now() + 5)
        }
      }
      #expect(holderEntered.wait(timeout: .now() + 2) == .success)

      let committed = LockedProviders()
      let clock = ContinuousClock()
      let started = clock.now
      let outcome = WindowsProviderSnapshotPublisher.publish([
        WindowsProviderSnapshot(
          provider: .poe,
          availability: .available,
          sourceText: "Manual · WSL CLI · Ubuntu")
      ]) { snapshot in
        committed.append(snapshot.provider)
      }
      let elapsed = started.duration(to: clock.now)

      #expect(elapsed < .seconds(1))
      #expect(outcome.rejectedProviders == [.poe])
      #expect(outcome.requiresRefresh)
      #expect(committed.value.isEmpty)
      releaseHolder.signal()
      try await holder.value
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
#endif
