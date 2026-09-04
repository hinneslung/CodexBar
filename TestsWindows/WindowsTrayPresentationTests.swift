#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  import WinSDK
  @testable import CodexBarWindows

  struct WindowsTrayPresentationTests {
    @Test
    func `presentation defaults to the initially enabled providers`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .claude,
            availability: .available,
            usedPercent: 42,
            resetText: "Resets in 3 hours",
            sourceText: "OAuth")
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))

      #expect(presentation.rows.map(\.provider) == WindowsProviderID.initiallyEnabledProviders)
      #expect(presentation.rows[1].percentText == "42% used")
      #expect(presentation.rows[0].statusText == "Unavailable")
    }

    @Test
    func `presentation clamps percent and normalizes multiline display text`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .codex,
            availability: .error,
            usedPercent: 140,
            resetText: "Tomorrow\n09:00",
            sourceText: "Core",
            safeErrorText: "Usage unavailable\r\nRetry later")
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))

      let row = presentation.rows[0]
      #expect(row.percentText == "100% used")
      #expect(row.resetText == "Tomorrow 09:00")
      #expect(row.errorText == "Usage unavailable Retry later")
      #expect(!row.accessibilityText.contains("\n"))
      #expect(row.dashboardText.hasPrefix("Codex — Error\r\n"))
      #expect(row.dashboardText.contains("100% used  •  Tomorrow 09:00"))
      #expect(row.dashboardText.contains("Source: Core  •  Usage unavailable Retry later"))
    }

    @Test
    func `presentation names OpenCode without exposing bridge terminology`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .poe,
            availability: .available,
            source: .init(
              distributionLabel: "Ubuntu",
              kind: .openCode,
              isResolved: true),
            balanceText: "4321 points remaining")
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providers: [.poe])

      let row = presentation.rows[0]
      #expect(row.sourceText == "Ubuntu · OpenCode")
      #expect(!row.accessibilityText.contains("bridge"))
    }

    @Test
    func `presentation preserves structured windows for overview and provider details`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .githubCopilot,
            availability: .available,
            sourceText: "WSL Ubuntu credential file",
            windows: [
              WindowsProviderWindowSnapshot(
                label: "Premium",
                usedPercent: 20,
                resetText: "Resets next month"),
              WindowsProviderWindowSnapshot(label: "Chat", usedPercent: 50),
            ],
            planText: "Plan: pro",
            balanceText: "12 credits used",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_100),
        providers: [.githubCopilot])

      let row = presentation.rows[0]
      #expect(row.windows.map(\.label) == ["Premium", "Chat"])
      #expect(row.windows.map(\.percentText) == ["20% used", "50% used"])
      #expect(row.planText == "Plan: pro")
      #expect(row.balanceText == "12 credits used")
      #expect(row.sourceText == "WSL Ubuntu credential file")
      #expect(row.overviewStatusText == "pro  •  12 used")
      #expect(row.governingWindow?.label == "Chat")
      #expect(row.governingWindow?.overviewResetText.isEmpty == true)
      #expect(row.measuredText.hasPrefix("Measured "))
    }

    @Test
    func `balance only provider promotes its balance in overview context`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .poe,
            availability: .available,
            sourceText: "Environment",
            balanceText: "4321 points remaining")
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providers: [.poe])

      let row = presentation.rows[0]
      #expect(row.windows.isEmpty)
      #expect(row.overviewStatusText.isEmpty)
      #expect(!row.overviewStatusText.contains("Environment"))
      #expect(WindowsProviderBalanceFormatter.compact("1000000 points") == "1M pts")
      #expect(WindowsProviderBalanceFormatter.compact("1000000 points remaining") == "1M pts left")
      #expect(
        WindowsProviderBalanceFormatter.compact("991,856 points remaining") == "991.9k pts left")
      #expect(presentation.trayTooltip(showUsed: true).contains("Poe - 4.3k pts left"))
    }

    @Test
    func `global usage mode formats a compact tray tooltip with reset countdown`() {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .codex,
            availability: .available,
            sourceText: "Windows credential file",
            windows: [
              WindowsProviderWindowSnapshot(
                label: "Weekly",
                usedPercent: 38,
                resetsAt: now.addingTimeInterval(4 * 86400 + 3 * 3600))
            ])
        ],
        refreshedAt: now)

      let window = presentation.rows[0].windows[0]
      #expect(window.displayedPercentText(showUsed: true) == "38% used")
      #expect(window.displayedPercentText(showUsed: false) == "62% left")
      #expect(
        presentation.trayTooltip(showUsed: true, now: now) == """
          Codex - 38% 4d
          Claude - unavailable
          """)
      #expect(presentation.trayTooltip(showUsed: false, now: now).hasPrefix("Codex - 62% 4d\n"))
    }

    @Test
    func `tooltip omits quota label when governing window has no reset information`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .githubCopilot,
            availability: .available,
            sourceText: "Copilot CLI",
            windows: [WindowsProviderWindowSnapshot(label: "Premium", usedPercent: 51)])
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providers: [.githubCopilot])

      #expect(presentation.trayTooltip(showUsed: true) == "Copilot - 51%")
      #expect(presentation.rows[0].governingWindow?.overviewResetText.isEmpty == true)
    }

    @Test
    func `tray tooltip compacts textual reset duration when date is unavailable`() {
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .claude,
            availability: .available,
            sourceText: "Windows credential file",
            windows: [
              WindowsProviderWindowSnapshot(
                label: "Weekly",
                usedPercent: 42,
                resetText: "Resets in 3 hours")
            ])
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))

      #expect(presentation.trayTooltip(showUsed: false).contains("Claude - 58% 3h"))
    }

    @Test
    func `reset labels use duration weekday then date without reset prefix or timezone`() {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0)!

      #expect(
        WindowsResetLabelFormatter.label(
          resetsAt: now.addingTimeInterval(4 * 3600 + 9 * 60),
          description: nil,
          now: now,
          calendar: calendar) == "4h 9m")
      #expect(
        WindowsResetLabelFormatter.label(
          resetsAt: now.addingTimeInterval(3 * 86400),
          description: nil,
          now: now,
          calendar: calendar) == "Fri 22:13")
      #expect(
        WindowsResetLabelFormatter.label(
          resetsAt: now.addingTimeInterval(10 * 86400),
          description: nil,
          now: now,
          calendar: calendar) == "Nov 24, 22:13")
      #expect(
        WindowsResetLabelFormatter.label(
          resetsAt: nil,
          description: "Resets in 3 hours (UTC)") == "3h")
    }

    @Test
    func `tray tooltip mirrors every active overview provider in configured order`() {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(
            provider: .codex,
            availability: .available,
            sourceText: "Windows credential file",
            windows: [
              WindowsProviderWindowSnapshot(
                label: "Weekly",
                usedPercent: 38,
                resetsAt: now.addingTimeInterval(4 * 86400))
            ]),
          WindowsProviderSnapshot(
            provider: .claude,
            availability: .available,
            sourceText: "Windows credential file",
            windows: [
              WindowsProviderWindowSnapshot(
                label: "Weekly",
                usedPercent: 42,
                resetText: "Resets in 3 hours")
            ]),
          WindowsProviderSnapshot(
            provider: .poe,
            availability: .available,
            sourceText: "WSL Ubuntu credential file",
            balanceText: "4321 points remaining"),
          WindowsProviderSnapshot(
            provider: .githubCopilot,
            availability: .error,
            sourceText: "Copilot CLI",
            safeErrorText: "Usage unavailable"),
          WindowsProviderSnapshot(
            provider: .openCodeGo,
            availability: .loading,
            sourceText: "WSL Ubuntu credential file"),
        ],
        refreshedAt: now,
        providers: [.codex, .claude, .poe, .githubCopilot, .openCodeGo])

      #expect(
        presentation.trayTooltip(showUsed: false, now: now) == """
          Codex - 62% 4d
          Claude - 58% 3h
          Poe - 4.3k pts left
          Copilot - error
          OpenCode Go - loading
          """)
    }

    @Test
    func `tray tooltip omits only whole provider lines when active list exceeds Windows capacity`()
    {
      let providers = (0..<20).map { WindowsProviderID("provider-\($0)-with-long-name") }
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providers: providers)

      let tooltip = presentation.trayTooltip(showUsed: true)
      let lines = tooltip.split(separator: "\n").map(String.init)
      #expect(tooltip.utf16.count <= 127)
      #expect(lines.last?.hasPrefix("+") == true)
      #expect(lines.last?.hasSuffix(" more") == true)
      for line in lines.dropLast() {
        #expect(line.hasSuffix(" - unavailable"))
      }
    }

    @Test
    func `version four tray icon explicitly enables the standard hover tooltip`() {
      #expect(WindowsTrayApplication.addTrayIconFlags & UINT(NIF_SHOWTIP) != 0)
      #expect(WindowsTrayApplication.updateTrayTooltipFlags & UINT(NIF_SHOWTIP) != 0)
    }
  }
#endif
