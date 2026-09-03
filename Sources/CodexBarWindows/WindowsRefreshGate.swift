struct WindowsRefreshGate: Equatable, Sendable {
  enum Completion: Equatable, Sendable {
    case publish
    case restart
  }

  private(set) var isRunning = false
  private var isRestartQueued = false

  mutating func request() -> Bool {
    guard !self.isRunning else {
      self.isRestartQueued = true
      return false
    }
    self.isRunning = true
    return true
  }

  mutating func complete() -> Completion {
    precondition(self.isRunning, "A refresh must be running before it can complete.")
    self.isRunning = false
    guard self.isRestartQueued else { return .publish }
    self.isRestartQueued = false
    return .restart
  }
}
