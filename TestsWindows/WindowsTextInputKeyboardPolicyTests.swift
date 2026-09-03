#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows text input keyboard policy")
  struct WindowsTextInputKeyboardPolicyTests {
    @Test("Ctrl A selects all in standard and rich edit controls")
    func selectsAll() {
      #expect(Self.action(key: 0x41, control: true, className: "Edit") == .selectAll)
      #expect(Self.action(key: 0x41, control: true, className: "RICHEDIT50W") == .selectAll)
    }

    @Test("other Ctrl combinations go directly to the focused text control")
    func dispatchesNativeEditingOperations() {
      #expect(Self.action(key: 0x25, control: true, className: "Edit") == .dispatchToFocusedControl)
      #expect(
        Self.action(key: 0x27, control: true, className: "RICHEDIT50W")
          == .dispatchToFocusedControl)
      #expect(Self.action(key: 0x56, control: true, className: "Edit") == .dispatchToFocusedControl)
    }

    @Test("Ctrl R remains the application refresh shortcut")
    func keepsRefreshShortcut() {
      #expect(Self.action(key: 0x52, control: true, className: "Edit") == .refresh)
      #expect(Self.action(key: 0x52, control: true, className: nil) == .refresh)
    }

    @Test("dialog navigation remains responsible outside Ctrl text editing")
    func keepsDialogNavigation() {
      #expect(Self.action(key: 0x09, control: false, className: "Edit") == .dialogNavigation)
      #expect(Self.action(key: 0x41, control: true, className: "Button") == .dialogNavigation)
      #expect(Self.action(key: 0x41, control: false, className: "RICHEDIT50W") == .dialogNavigation)
    }

    private static func action(
      key: UInt32,
      control: Bool,
      className: String?
    ) -> WindowsTextInputKeyboardAction {
      WindowsTextInputKeyboardPolicy.action(
        virtualKey: key,
        controlDown: control,
        focusedControlClass: className)
    }
  }
#endif
