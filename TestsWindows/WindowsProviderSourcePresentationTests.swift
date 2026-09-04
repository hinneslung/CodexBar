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

    @Test("automatic credential guidance reflects verified provider methods")
    func automaticCredentialGuidance() {
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .kimi)
          == "Automatically uses this provider's OpenCode connection when available. Otherwise, it uses "
          + "credentials from its app or CLI or existing CodexBar CLI configuration. "
          + "Select a manual option if Automatic fails."
      )
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .amp)
          == "Automatically uses credentials from this provider's app or CLI or existing CodexBar CLI configuration. "
          + "Select a manual option if Automatic fails.")
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .codex)
          == "Automatically uses credentials from this provider's app or CLI or existing CodexBar CLI configuration."
      )
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .openCodeGo)
          == "Automatically uses this provider's OpenCode connection when available. Otherwise, it uses "
          + "credentials already configured in CodexBar CLI. "
          + "Select a manual option if Automatic fails.")
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .clinePass)
          == "Automatically uses this provider's OpenCode connection when available. Otherwise, it uses "
          + "credentials already configured in CodexBar CLI. "
          + "Select a manual option if Automatic fails.")
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .deepgram)
          == "Automatically uses credentials already configured in CodexBar CLI. "
          + "Select a manual option if Automatic fails.")
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .factory)
          == "Automatically uses credentials from this provider's app or CLI or existing CodexBar CLI configuration. "
          + "Select a manual option if Automatic fails.")
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .wayfinder)
          == "Automatically uses credentials from this provider's app or CLI or existing CodexBar CLI configuration."
      )

      for provider in WindowsProviderCatalog.entries.map(\.id) {
        let description =
          WindowsProviderConfigurationCatalog
          .automaticCredentialDescription(provider: provider)
        #expect(!description.contains("\n"))
      }
    }

    @Test("disabled summaries compose verified capabilities in order without duplicates")
    func summarizesCapabilities() {
      #expect(
        WindowsProviderCapabilityPresentation.labels(
          providerAppOrCLI: true,
          supportsOpenCode: true,
          manualLabels: ["API key", "Browser session", "Session token"])
          == ["Provider app/CLI", "OpenCode", "API key", "Browser session", "Session token"])
      #expect(
        WindowsProviderCapabilityPresentation.labels(
          providerAppOrCLI: true,
          supportsOpenCode: true,
          manualLabels: ["opencode", "PROVIDER APP/CLI", "API key", "api KEY"])
          == ["Provider app/CLI", "OpenCode", "API key"])
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .amp)
          == "Provider app/CLI · API key · Browser session")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .kimi)
          == "Provider app/CLI · OpenCode · API key")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .openCodeGo)
          == "OpenCode · API key · Browser session")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .codex)
          == "Provider app/CLI")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .factory)
          == "Provider app/CLI · API key")
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .wayfinder)
          == "Provider app/CLI")

      for provider in WindowsProviderCatalog.entries.map(\.id) {
        let summary = WindowsProviderCapabilityPresentation.summary(provider: provider)
        #expect(!summary.components(separatedBy: " · ").contains("Auto"))
        let labels =
          summary
          .components(separatedBy: " · ")
        #expect(Set(labels.map { $0.lowercased() }).count == labels.count)
      }
    }

    @Test("manual capability summaries preserve session and browser credential labels")
    func preservesManualCapabilityLabels() {
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .stepFun)
          .components(separatedBy: " · ").contains("Session token"))

      for provider in [
        WindowsProviderID.alibabaTokenPlan, .amp, .commandCode, .cursor, .grok,
        .ollama, .openCodeGo, .qoder, .qwenCloud, .sakana,
      ] {
        #expect(
          WindowsProviderCapabilityPresentation.summary(provider: provider)
            .components(separatedBy: " · ").contains("Browser session"))
      }
    }

    @Test("every usable provider has a verified capability subtitle")
    func usableProvidersHaveCapabilitySummary() {
      for provider in WindowsProviderCatalog.entries.map(\.id) {
        guard !WindowsProviderConfigurationCatalog.unavailableProviderIDs.contains(provider)
        else { continue }
        #expect(!WindowsProviderCapabilityPresentation.summary(provider: provider).isEmpty)
      }
      #expect(
        WindowsProviderCapabilityPresentation.summary(provider: .cursor)
          == "Browser session")
    }

    @Test("provider sign-in metadata remains tied to reviewed upstream routes")
    func providerSignInMetadataMatchesUpstreamEvidence() throws {
      let cliProviders: Set<WindowsProviderID> = [
        .amp, .antigravity, .augment, .claude, .codex, .doubao, .grok, .kilo, .kiro,
      ]
      let providerStateProviders: Set<WindowsProviderID> = [
        .bedrock, .codebuff, .gemini, .jetBrains, .kimi, .vertexAI,
      ]
      let localSourceProviders: Set<WindowsProviderID> = [.factory, .wayfinder]
      #expect(
        WindowsProviderConfigurationCatalog.providerAppOrCLIProviderIDs
          == cliProviders.union(providerStateProviders).union(localSourceProviders))
      #expect(
        Set(
          WindowsProviderConfigurationCatalog.providerAppOrCLIEvidence
            .compactMap { provider, evidence in
              evidence == .providerCLI ? provider : nil
            }) == cliProviders)
      #expect(
        Set(
          WindowsProviderConfigurationCatalog.providerAppOrCLIEvidence
            .compactMap { provider, evidence in
              evidence == .providerOwnedAuthenticationState ? provider : nil
            }) == providerStateProviders)
      #expect(
        Set(
          WindowsProviderConfigurationCatalog.providerAppOrCLIEvidence
            .compactMap { provider, evidence in
              evidence == .providerOwnedLocalSource ? provider : nil
            }) == localSourceProviders)

      let descriptorPaths: [WindowsProviderID: String] = [
        .amp: "Amp/AmpProviderDescriptor.swift",
        .antigravity: "Antigravity/AntigravityProviderDescriptor.swift",
        .augment: "Augment/AugmentProviderDescriptor.swift",
        .claude: "Claude/ClaudeProviderDescriptor.swift",
        .codex: "Codex/CodexProviderDescriptor.swift",
        .doubao: "Doubao/DoubaoProviderDescriptor.swift",
        .grok: "Grok/GrokProviderDescriptor.swift",
        .kilo: "Kilo/KiloProviderDescriptor.swift",
        .kiro: "Kiro/KiroProviderDescriptor.swift",
      ]
      for provider in cliProviders {
        let relativePath = try #require(descriptorPaths[provider])
        let descriptor = try Self.upstreamProviderSource(relativePath)
        let sourceModes = try #require(Self.sourceModes(in: descriptor))
        #expect(sourceModes.contains(".cli"), "Missing reviewed CLI source mode for \(provider)")
      }

      let stateEvidence: [(String, String)] = [
        ("Bedrock/BedrockProviderDescriptor.swift", "BedrockSettingsReader.profile(environment:"),
        (
          "Codebuff/CodebuffProviderDescriptor.swift",
          "CodebuffSettingsReader.authToken(authFileURL:"
        ),
        (
          "Gemini/GeminiStatusProbe.swift",
          "private static let credentialsPath = \"/.gemini/oauth_creds.json\""
        ),
        (
          "JetBrains/JetBrainsProviderDescriptor.swift", "let kind: ProviderFetchKind = .localProbe"
        ),
        (
          "Kimi/KimiProviderDescriptor.swift",
          "KimiSettingsReader.hasKimiCodeCredential(environment:"
        ),
        (
          "VertexAI/VertexAIProviderDescriptor.swift",
          "VertexAIOAuthCredentialsStore.hasCredentials(environment:"
        ),
      ]
      for (relativePath, marker) in stateEvidence {
        #expect(try Self.upstreamProviderSource(relativePath).contains(marker))
      }
      let localSourceEvidence: [(String, String)] = [
        ("Factory/FactoryProviderDescriptor.swift", "FactorySettingsReader.apiKey(environment:"),
        ("Wayfinder/WayfinderProviderDescriptor.swift", "WayfinderGatewayFetchStrategy()"),
      ]
      for (relativePath, marker) in localSourceEvidence {
        #expect(try Self.upstreamProviderSource(relativePath).contains(marker))
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

      for provider: WindowsProviderID in [.amp, .codebuff, .doubao, .factory, .kilo] {
        let snapshot = try WindowsCanonicalCLIProviderClient.decode(
          data: try Self.payload(source: "api", provider: provider),
          requestedProvider: provider,
          source: automatic)
        #expect(snapshot.sourceText == "Ubuntu · API key")
      }

      let wayfinder = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "api", provider: .wayfinder),
        requestedProvider: .wayfinder,
        source: automatic)
      let bedrock = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "api", provider: .bedrock),
        requestedProvider: .bedrock,
        source: automatic)
      #expect(wayfinder.sourceText == "Ubuntu · Provider app/CLI")
      #expect(bedrock.sourceText == "Ubuntu · Provider app/CLI")

      let ampCLI = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "cli", provider: .amp),
        requestedProvider: .amp,
        source: automatic)
      #expect(ampCLI.sourceText == "Ubuntu · Provider CLI")
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
      let factory = try WindowsCanonicalCLIProviderClient.decode(
        data: try Self.payload(source: "api", provider: .factory),
        requestedProvider: .factory,
        source: .init(
          distributionLabel: "Ubuntu",
          kind: .manual("API key"),
          isResolved: false))

      #expect(manual.sourceText == "Debian · API key")
      #expect(openCode.sourceText == "Ubuntu · OpenCode")
      #expect(factory.sourceText == "Ubuntu · API key")
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

    private static func upstreamProviderSource(_ relativePath: String) throws -> String {
      let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let url =
        repositoryRoot
        .appendingPathComponent("Sources/CodexBarCore/Providers", isDirectory: true)
        .appendingPathComponent(relativePath, isDirectory: false)
      return try String(contentsOf: url, encoding: .utf8)
    }

    private static func sourceModes(in descriptor: String) -> Substring? {
      guard let start = descriptor.range(of: "sourceModes:")?.upperBound,
        let end = descriptor[start...].firstIndex(of: "]")
      else { return nil }
      return descriptor[start..<end]
    }
  }
#endif
