import Foundation

enum WindowsTextInputKeyboardAction: Equatable, Sendable {
  case dialogNavigation
  case dispatchToFocusedControl
  case selectAll
  case refresh
}

enum WindowsTextInputKeyboardPolicy {
  static func action(
    virtualKey: UInt32,
    controlDown: Bool,
    focusedControlClass: String?
  ) -> WindowsTextInputKeyboardAction {
    guard controlDown else { return .dialogNavigation }
    if virtualKey == 0x52 { return .refresh }
    guard self.isTextInputClass(focusedControlClass) else { return .dialogNavigation }
    return virtualKey == 0x41 ? .selectAll : .dispatchToFocusedControl
  }

  private static func isTextInputClass(_ className: String?) -> Bool {
    guard let className else { return false }
    return switch className.lowercased() {
    case "edit", "richedit50w":
      true
    default:
      false
    }
  }
}
