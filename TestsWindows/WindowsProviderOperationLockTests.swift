#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider operation lock")
  struct WindowsProviderOperationLockTests {
    @Test("vault mutation waits for an active provider operation")
    func serializesProviderOperations() async throws {
      let firstEntered = DispatchSemaphore(value: 0)
      let releaseFirst = DispatchSemaphore(value: 0)
      let secondEntered = LockedFlag()

      let first = Task.detached {
        try WindowsProviderOperationLock.withLock(provider: .poe) {
          firstEntered.signal()
          _ = releaseFirst.wait(timeout: .now() + 5)
        }
      }
      #expect(firstEntered.wait(timeout: .now() + 2) == .success)
      let second = Task.detached {
        try WindowsProviderOperationLock.withLock(provider: .poe) {
          secondEntered.set()
        }
      }
      try? await Task.sleep(for: .milliseconds(150))
      #expect(!secondEntered.value)
      releaseFirst.signal()
      try await first.value
      try await second.value
      #expect(secondEntered.value)
    }
  }

  private final class LockedFlag: @unchecked Sendable {
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
