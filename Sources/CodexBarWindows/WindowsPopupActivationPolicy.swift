enum WindowsPopupActivationAction: Equatable, Sendable {
  case showFromTray
  case hide
  case ignoreDuplicateTrayActivation
  case scheduleDeferredHide
  case cancelDeferredHideAndReactivate
  case none
}

struct WindowsPopupActivationPolicy: Sendable {
  private(set) var isAwaitingPostTrayActivation = false

  mutating func trayActivated(isPopupVisible: Bool) -> WindowsPopupActivationAction {
    if self.isAwaitingPostTrayActivation {
      return .ignoreDuplicateTrayActivation
    }
    if isPopupVisible {
      return .hide
    }
    self.isAwaitingPostTrayActivation = true
    return .showFromTray
  }

  func deactivated(automaticallyHides: Bool) -> WindowsPopupActivationAction {
    automaticallyHides ? .scheduleDeferredHide : .none
  }

  mutating func postTrayActivationTimerFired(isPopupVisible: Bool) -> WindowsPopupActivationAction {
    guard self.isAwaitingPostTrayActivation else { return .none }
    self.isAwaitingPostTrayActivation = false
    return isPopupVisible ? .cancelDeferredHideAndReactivate : .none
  }

  mutating func deferredHideTimerFired(isPopupVisible: Bool) -> WindowsPopupActivationAction {
    guard isPopupVisible else {
      self.isAwaitingPostTrayActivation = false
      return .none
    }
    if self.isAwaitingPostTrayActivation {
      self.isAwaitingPostTrayActivation = false
      return .cancelDeferredHideAndReactivate
    }
    return .hide
  }

  mutating func popupHidden() {
    self.isAwaitingPostTrayActivation = false
  }
}

struct WindowsTrayActivationGate: Sendable {
  private static let duplicateWindowMilliseconds: UInt32 = 250
  private var lastActivationTimestamp: UInt32?

  mutating func shouldHandle(timestamp: UInt32) -> Bool {
    defer { self.lastActivationTimestamp = timestamp }
    guard let lastActivationTimestamp else { return true }
    return timestamp &- lastActivationTimestamp > Self.duplicateWindowMilliseconds
  }
}
