#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider source presentation")
  struct WindowsProviderSourcePresentationTests {
    @Test("formatter keeps the distribution first for every source kind")
    func formatsDistroFirst() {
      #expect(Self.source(.automatic) == "Ubuntu · Automatic")
      #expect(Self.source(.manual("API key")) == "Ubuntu · API key")
      #expect(Self.source(.openCode) == "Ubuntu · OpenCode")
      #expect(Self.source(.upstream("oauth"), resolved: true) == "Ubuntu · OAuth")
      #expect(Self.source(.upstream("Claude CLI"), resolved: true) == "Ubuntu · Claude CLI")
      #expect(
        WindowsProviderSourcePresentation(
          distributionLabel: "  ",
          kind: .automatic,
          isResolved: false
        ).formattedValue == "Automatic distro · Automatic")
    }

    @Test("enabled settings and provider detail use the identical shared value")
    func sharesEnabledValue() throws {
      let source = WindowsProviderSourcePresentation(
        distributionLabel: "Ubuntu",
        kind: .openCode,
        isResolved: true)
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [
          WindowsProviderSnapshot(provider: .poe, availability: .available, source: source)
        ],
        refreshedAt: Date(),
        providers: [.poe])
      let configuration = WindowsProviderConfiguration(
        id: .poe,
        enabled: true,
        order: 0,
        sourceMode: .wsl,
        wslDistro: "Ubuntu")
      let detailValue = try #require(presentation.rows.first?.sourceText)

      #expect(detailValue == "Ubuntu · OpenCode")
      #expect(
        WindowsProviderSettingsPresentation.subtitle(
          configuration: configuration,
          sourceText: detailValue) == detailValue)
      #expect(!detailValue.localizedCaseInsensitiveContains("bridge"))
    }

    @Test("enabled settings uses configured fallback when no snapshot exists")
    func enabledSettingsUsesConfiguredFallback() throws {
      let configuration = WindowsProviderConfiguration(
        id: .poe,
        enabled: true,
        order: 0,
        sourceMode: .automatic)
      let presentation = WindowsDashboardPresentation.make(
        snapshots: [],
        refreshedAt: Date(),
        providers: [.poe])
      let placeholder = try #require(presentation.rows.first?.sourceText)
      let detailValue = WindowsProviderSettingsPresentation.subtitle(
        configuration: configuration,
        sourceText: placeholder)

      #expect(placeholder == "Source unavailable")
      #expect(detailValue == "Automatic distro · Automatic")
      #expect(
        WindowsProviderSettingsPresentation.subtitle(
          configuration: configuration,
          sourceText: placeholder) == detailValue)

      var explicit = configuration
      explicit.sourceMode = .wsl
      explicit.wslDistro = "Ubuntu"
      #expect(
        WindowsProviderSettingsPresentation.subtitle(
          configuration: explicit,
          sourceText: placeholder) == "Ubuntu · Automatic")
    }

    @Test("disabled summaries derive OpenCode and manual capabilities without duplicates")
    func summarizesCapabilities() {
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .openCodeGo)
          == "Auto · OpenCode · API key · Browser session")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .codex) == "Auto")

      for provider in WindowsProviderCatalog.entries.map(\.id) {
        let labels = WindowsProviderCapabilityPresentation.summary(provider: provider)
          .components(separatedBy: " · ")
        #expect(Set(labels.map { $0.lowercased() }).count == labels.count)
      }
    }

    @Test("unavailable provider metadata is the single configuration gate")
    func unavailableProviderMetadata() throws {
      let expected: Set<WindowsProviderID> = [.abacus, .devin, .windsurf, .zed]
      #expect(WindowsProviderConfigurationCatalog.unavailableProviderIDs == expected)
      #expect(Set(WindowsProviderConfigurationCatalog.unavailableProviders.keys) == expected)

      for provider in expected {
        let info = try #require(WindowsProviderConfigurationCatalog.unavailableInfo(for: provider))
        #expect(!info.explanation.isEmpty)
        #expect(info.resourceURL?.hasPrefix("https://github.com/steipete/CodexBar/") == true)
        #expect(!WindowsProviderConfigurationCatalog.supportsConfigurationControls(for: provider))
        #expect(
          WindowsProviderCapabilityPresentation.summary(provider: provider)
            == "Unavailable on Windows")
      }
      #expect(WindowsProviderConfigurationCatalog.supportsConfigurationControls(for: .codex))
    }

    @Test("canonical source decoding normalizes generic and preserves specific upstream labels")
    func decodesUpstreamSource() throws {
      let automatic = WindowsProviderSourcePresentation(
        distributionLabel: "Ubuntu",
        kind: .automatic,
        isResolved: false)
      let api = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "api"),
        requestedProvider: .poe,
        source: automatic)
      let specific = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "  Claude CLI\n"),
        requestedProvider: .poe,
        source: automatic)

      #expect(api.sourceText == "Ubuntu · API key")
      #expect(api.source.isResolved)
      #expect(specific.sourceText == "Ubuntu · Claude CLI")
    }

    @Test("canonical source decoding recognizes provider and mechanism patterns")
    func recognizesProviderAndMechanismPatterns() throws {
      let automatic = WindowsProviderSourcePresentation(
        distributionLabel: "Ubuntu",
        kind: .automatic,
        isResolved: false)

      #expect(
        try Self.decodedSource("claude", provider: .claude, from: automatic)
          == "Ubuntu · Claude CLI")
      #expect(
        try Self.decodedSource("codex-cli", provider: .codex, from: automatic)
          == "Ubuntu · Codex CLI")
      #expect(
        try Self.decodedSource("admin-api", provider: .claude, from: automatic)
          == "Ubuntu · Admin API")
      #expect(
        try Self.decodedSource("grok-web", provider: .grok, from: automatic)
          == "Ubuntu · Browser session")
      #expect(
        try Self.decodedSource("deployment", provider: .azureOpenAI, from: automatic)
          == "Ubuntu · Deployment")
    }

    @Test("canonical source decoding rejects controls and bounds combining sequences")
    func sanitizesUntrustedUpstreamSource() throws {
      let automatic = WindowsProviderSourcePresentation(
        distributionLabel: "Ubuntu",
        kind: .automatic,
        isResolved: false)
      for unsafe in ["\u{202E}egdirb edoCnepO", "OAuth\0hidden", "CLI\u{0007}alert"] {
        let snapshot = try WindowsCanonicalCLIProviderClient.decode(
          data: try Self.payload(source: unsafe),
          requestedProvider: .poe,
          source: automatic)
        #expect(snapshot.sourceText == "Ubuntu · Automatic")
      }

      let combining = "A" + String(repeating: "\u{0301}", count: 400)
      let bounded = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: combining),
        requestedProvider: .poe,
        source: automatic)
      let sourceLabel = try #require(bounded.sourceText.split(separator: "·", maxSplits: 1).last)
        .trimmingCharacters(in: .whitespaces)
      #expect(sourceLabel.unicodeScalars.count == 150)
    }

    @Test("manual and OpenCode routes override lower level upstream attribution")
    func routeOverridesUpstream() throws {
      let manual = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "oauth"),
        requestedProvider: .poe,
        source: .init(distributionLabel: "Debian", kind: .manual("API key"), isResolved: false))
      let openCode = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "api"),
        requestedProvider: .poe,
        source: .init(distributionLabel: "Ubuntu", kind: .openCode, isResolved: false))

      #expect(manual.sourceText == "Debian · API key")
      #expect(openCode.sourceText == "Ubuntu · OpenCode")
      #expect(!openCode.sourceText.contains("OpenCode · WSL CLI"))
      #expect(manual.source.isResolved)
      #expect(openCode.source.isResolved)
    }

    @Test("failed automatic fetch does not claim a concrete mechanism")
    func failedAutomaticStaysAutomatic() async {
      let invocation = WindowsCanonicalCLIInvocation(
        executablePath: "C:\\does-not-run.exe",
        arguments: [],
        source: .init(distributionLabel: "Ubuntu", kind: .automatic, isResolved: false),
        distribution: "Ubuntu",
        standardInput: nil,
        allowsRetry: false)
      let snapshot = await WindowsCanonicalCLIProviderClient().fetch(
        provider: .poe,
        invocation: invocation)

      #expect(snapshot.availability == .unavailable)
      #expect(snapshot.sourceText == "Ubuntu · Automatic")
      #expect(!snapshot.source.isResolved)
    }

    @Test("stale-success presentation retains the successful resolved source")
    func staleSuccessKeepsResolvedSource() {
      let cached = WindowsProviderSnapshot(
        provider: .poe,
        availability: .available,
        usedPercent: 20,
        source: .init(distributionLabel: "Ubuntu", kind: .upstream("oauth"), isResolved: true))
      let failed = WindowsProviderSnapshot(
        provider: .poe,
        availability: .error,
        source: .init(distributionLabel: "Debian", kind: .automatic, isResolved: false),
        safeErrorText: "Usage unavailable")
      let retained = WindowsTrayApplication.snapshotRetainingLastSuccess(failed, cached: cached)

      #expect(retained.sourceText == "Ubuntu · OAuth")
      #expect(retained.usedPercent == 20)
      #expect(retained.safeErrorText?.contains("last successful") == true)
    }

    @Test("stale values use the current explicit manual route")
    func staleValuesUseManualRoute() {
      let cached = WindowsProviderSnapshot(
        provider: .openRouter,
        availability: .available,
        usedPercent: 20,
        source: .init(distributionLabel: "Ubuntu", kind: .upstream("api"), isResolved: true))
      let failed = WindowsProviderSnapshot(
        provider: .openRouter,
        availability: .error,
        source: .init(distributionLabel: "Ubuntu", kind: .manual("API key"), isResolved: false),
        safeErrorText: "Usage unavailable")

      let retained = WindowsTrayApplication.snapshotRetainingLastSuccess(failed, cached: cached)

      #expect(retained.sourceText == "Ubuntu · API key")
      #expect(retained.usedPercent == 20)
      #expect(retained.safeErrorText?.contains("last successful") == true)
    }

    @Test("refreshing presentation overlays the selected manual route")
    func refreshingPresentationUsesManualRoute() {
      let cached = WindowsProviderSnapshot(
        provider: .openRouter,
        availability: .available,
        usedPercent: 20,
        source: .init(distributionLabel: "Ubuntu", kind: .upstream("api"), isResolved: true))
      let configuration = WindowsProviderConfiguration(
        id: .openRouter,
        enabled: true,
        order: 0)

      let refreshing = WindowsTrayApplication.snapshotForRefreshPresentation(
        cached,
        configuration: configuration,
        manualCredentialLabel: "API key")

      #expect(refreshing.sourceText == "Ubuntu · API key")
      #expect(!refreshing.source.isResolved)
      #expect(refreshing.usedPercent == 20)
    }

    @Test("refreshing presentation removes a cleared manual route")
    func refreshingPresentationClearsManualRoute() {
      let cached = WindowsProviderSnapshot(
        provider: .openRouter,
        availability: .available,
        source: .init(distributionLabel: "Ubuntu", kind: .manual("API key"), isResolved: true))
      let configuration = WindowsProviderConfiguration(
        id: .openRouter,
        enabled: true,
        order: 0)

      let refreshing = WindowsTrayApplication.snapshotForRefreshPresentation(
        cached,
        configuration: configuration,
        manualCredentialLabel: nil)

      #expect(refreshing.sourceText == "Ubuntu · Automatic")
      #expect(!refreshing.source.isResolved)
    }

    private static func source(
      _ kind: WindowsProviderSourcePresentation.Kind,
      resolved: Bool = false
    ) -> String {
      WindowsProviderSourcePresentation(
        distributionLabel: "Ubuntu",
        kind: kind,
        isResolved: resolved
      ).formattedValue
    }

    private static func decodedSource(
      _ source: String,
      provider: WindowsProviderID,
      from presentation: WindowsProviderSourcePresentation
    ) throws -> String {
      try WindowsCanonicalCLIProviderClient.decode(
        data: Self.payload(source: source, provider: provider),
        requestedProvider: provider,
        source: presentation
      ).sourceText
    }

    private static func payload(
      source: String,
      provider: WindowsProviderID = .poe
    ) throws -> Data {
      let payload: [String: Any] = [
        "provider": provider.rawValue,
        "source": source,
        "usage": [
          "primary": NSNull(),
          "secondary": NSNull(),
          "tertiary": NSNull(),
          "extraRateWindows": [],
          "updatedAt": "2026-08-24T01:00:00Z",
          "identity": NSNull(),
        ],
        "credits": NSNull(),
        "error": NSNull(),
      ]
      return try JSONSerialization.data(withJSONObject: payload)
    }
  }
#endif
