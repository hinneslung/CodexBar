#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  struct WindowsApplicationIdentityTests {
    @Test
    func `bundled Windows icon loads native large and small handles`() {
      let icon = WindowsApplicationIcon.load()

      #expect(icon.usesBundledIcon)
      #expect(icon.large != nil)
      #expect(icon.small != nil)
    }
  }
#endif
