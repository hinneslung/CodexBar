#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  struct WindowsProviderSourceStatusTests {
    @Test
    func `successful and unchecked sources do not produce settings messages`() {
      #expect(WindowsProviderSourceStatus.errorText(row: nil) == nil)

      let row = WindowsProviderRowPresentation(
        provider: .codex,
        statusText: "Available",
        percentText: "20% used",
        resetText: "Reset unavailable",
        sourceText: "Source: Windows CodexBar CLI",
        errorText: "",
        windows: [],
        planText: "",
        balanceText: "",
        accountText: "",
        measuredText: "")
      #expect(WindowsProviderSourceStatus.errorText(row: row) == nil)
    }

    @Test
    func `WSL CLI is an application source without provider specific input`() {
      let row = WindowsProviderRowPresentation(
        provider: .codex,
        statusText: "Unavailable",
        percentText: "Usage unavailable",
        resetText: "Reset unavailable",
        sourceText: "Source: WSL CLI",
        errorText: "CodexBar CLI was not found in any installed WSL distribution.",
        windows: [],
        planText: "",
        balanceText: "",
        accountText: "",
        measuredText: "")

      #expect(
        WindowsProviderSourceStatus.errorText(row: row)
          == "CodexBar CLI was not found in any installed WSL distribution.")
    }

    @Test
    func `applied source surfaces only its provider error`() {
      let saved = WindowsProviderConfiguration(
        id: .claude,
        enabled: true,
        order: 0,
        sourceMode: .automatic)
      let row = WindowsProviderRowPresentation(
        provider: .claude,
        statusText: "Unavailable",
        percentText: "Usage unavailable",
        resetText: "Reset unavailable",
        sourceText: "Source: Windows CodexBar CLI",
        errorText: "Claude usage could not be loaded.",
        windows: [],
        planText: "",
        balanceText: "",
        accountText: "",
        measuredText: "")

      #expect(
        WindowsProviderConfigurationPageState.errorText(
          provider: .claude,
          lastAppliedProvider: nil,
          draft: saved,
          saved: saved,
          isRefreshing: false,
          row: row) == nil)
      #expect(
        WindowsProviderConfigurationPageState.errorText(
          provider: .claude,
          lastAppliedProvider: .claude,
          draft: saved,
          saved: saved,
          isRefreshing: false,
          row: row) == "Claude usage could not be loaded.")
      #expect(
        WindowsProviderConfigurationPageState.errorText(
          provider: .claude,
          lastAppliedProvider: .claude,
          draft: saved,
          saved: saved,
          isRefreshing: true,
          row: row) == nil)

      var edited = saved
      edited.sourceMode = .wsl
      edited.wslDistro = "Ubuntu"
      #expect(WindowsProviderConfigurationPageState.hasUnsavedChanges(draft: edited, saved: saved))
      #expect(
        WindowsProviderConfigurationPageState.errorText(
          provider: .claude,
          lastAppliedProvider: .claude,
          draft: edited,
          saved: saved,
          isRefreshing: false,
          row: row) == nil)

      var legacyAutomatic = saved
      legacyAutomatic.wslDistro = "ignored-stale-value"
      #expect(
        !WindowsProviderConfigurationPageState.hasUnsavedChanges(
          draft: legacyAutomatic,
          saved: saved))
    }
  }
#endif
