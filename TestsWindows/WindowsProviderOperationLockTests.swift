#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider operation lock")
  struct WindowsProviderOperationLockTests {
    @Test("vault mutation waits for an active provider operation")
    func serializesProviderOperations() async throws {
      let provider = WindowsProviderID.abacus
      let firstEntered = LockedFlag()
      let releaseFirst = DispatchSemaphore(value: 0)
      let secondAttempted = LockedFlag()
      let secondEntered = LockedFlag()

      let first = Task {
        try await runProviderLockOperation {
          try WindowsProviderOperationLock.withLock(provider: provider) {
            firstEntered.set()
            guard releaseFirst.wait(timeout: .now() + 5) == .success else {
              throw ProviderOperationLockTestError.timedOut
            }
          }
        }
      }
      defer { releaseFirst.signal() }
      try await waitForProviderLockCondition(timeout: .seconds(2)) { firstEntered.value }
      let second = Task {
        try await runProviderLockOperation {
          secondAttempted.set()
          try WindowsProviderOperationLock.withLock(provider: provider) {
            secondEntered.set()
          }
        }
      }
      try await waitForProviderLockCondition(timeout: .seconds(2)) { secondAttempted.value }
      try? await Task.sleep(for: .milliseconds(150))
      #expect(!secondEntered.value)
      releaseFirst.signal()
      try await first.value
      try await second.value
      #expect(secondEntered.value)
    }
  }

  private enum ProviderOperationLockTestError: Error {
    case timedOut
  }

  private func runProviderLockOperation(
    _ operation: @escaping @Sendable () throws -> Void
  ) async throws {
    let queue = DispatchQueue(label: "CodexBarTests.ProviderOperationLock")
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

  private func waitForProviderLockCondition(
    timeout: Duration,
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw ProviderOperationLockTestError.timedOut }
      try await Task.sleep(for: .milliseconds(10))
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
