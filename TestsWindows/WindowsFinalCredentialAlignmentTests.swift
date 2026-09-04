#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows final credential alignment", .serialized)
  struct WindowsFinalCredentialAlignmentTests {
    private static let diagnosticProviders: Set<WindowsProviderID> = [
      .longCat, .manus, .mistral, .notion, .openCode, .perplexity, .stepFun,
      .t3Chat, .mimo, .zoomMate,
    ]

    @Test("catalog method counts and aligned provider copy are exact")
    func catalogInvariants() throws {
      let schemas = WindowsProviderConfigurationCatalog.schemas
      let manualSets = schemas.flatMap(\.manualCredentialSets)
      #expect(manualSets.count(where: { $0.id == "api-key" }) == 39)
      #expect(manualSets.count(where: { $0.label == "Browser session" }) == 19)
      #expect(manualSets.count(where: { $0.label == "Session token" }) == 1)

      for provider in [WindowsProviderID.clinePass, .deepSeek, .minimax] {
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[provider])
        #expect(
          ["Automatic"] + schema.manualCredentialSets.map(\.label) == ["Automatic", "API key"])
        #expect(
          WindowsProviderCapabilityPresentation.summary(provider: provider) == "OpenCode · API key")
        #expect(
          WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: provider)
            == "Automatically uses this provider's OpenCode connection when available. Otherwise, it uses "
            + "credentials already configured in CodexBar CLI. "
            + "Select a manual option if Automatic fails.")
      }

      for schema in schemas {
        #expect(
          schema.automaticExecutionMode
            == (Self.diagnosticProviders.contains(schema.provider) ? .diagnose : .usage))
      }
      #expect(
        Set(schemas.filter { $0.automaticExecutionMode == .diagnose }.map(\.provider))
          == Self.diagnosticProviders)
      #expect(
        Set(
          schemas.compactMap { schema in
            schema.credentialSets.contains(where: { $0.secretTransport == .stagedTokenAccount })
              ? schema.provider : nil
          }) == [.deepSeek])
      #expect(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: .stepFun)
          == "Automatically uses credentials already configured in CodexBar CLI. "
          + "Select a manual option if Automatic fails."
      )

      for schema in schemas {
        let invocation = WindowsCanonicalCLIInvocation.wsl(
          distribution: "Ubuntu",
          executablePath: "/opt/codexbar/CodexBarCLI",
          providerID: schema.cliName,
          executionMode: schema.automaticExecutionMode,
          windowsDirectory: "C:\\Windows")
        let command = Array(invocation.arguments.dropFirst(4))
        if Self.diagnosticProviders.contains(schema.provider) {
          #expect(
            command == [
              "diagnose", "--provider", schema.cliName, "--format", "json", "--redact",
            ])
          #expect(invocation.processTimeout == 90)
        } else {
          #expect(command == ["usage", "--provider", schema.cliName, "--json-only"])
          #expect(invocation.processTimeout == 45)
        }
      }
    }

    @Test("MiniMax accepts only nonempty Coding Plan keys with pinned safe guidance")
    func minimaxValidation() throws {
      let set = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.minimax]?.credentialSet(id: "api-key"))
      let field = try #require(set.fields.first)
      let message = "Enter a MiniMax Coding Plan key beginning with sk-cp-."
      #expect(field.label == "API key")
      #expect(field.normalized("  sk-cp-fixture  ") == "sk-cp-fixture")
      #expect(field.displaySafeValidationMessage("  sk-cp-fixture  ") == nil)
      let rejectedValues = [
        "", "sk-cp-", "sk-api-fixture", "SK-CP-fixture", "other", "'sk-cp-fixture'",
        "sk-cp-fixture\nmalformed",
      ]
      for rejected in rejectedValues {
        #expect(field.normalized(rejected) == nil)
        #expect(field.displaySafeValidationMessage(rejected) == message)
      }

      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codexbar-minimax-validation-\(Foundation.UUID().uuidString)",
        isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      for rejected in rejectedValues {
        #expect(throws: WindowsProviderCredentialVaultError.validationRejected(message)) {
          try vault.save(
            provider: .minimax,
            credentialSetID: set.id,
            submittedValues: ["apiKey": rejected])
        }
        let invalidRecord = WindowsProviderCredentialRecord(
          provider: .minimax,
          credentialSetID: set.id,
          values: ["apiKey": rejected])
        #expect(throws: WindowsStagedProviderConfigError.validationRejected(message)) {
          try WindowsStagedProviderConfig.encodeManual(provider: .minimax, record: invalidRecord)
        }
      }
      #expect(!vault.contains(.minimax))
      let saved = try vault.save(
        provider: .minimax,
        credentialSetID: set.id,
        submittedValues: ["apiKey": "  sk-cp-fixture  "])
      #expect(saved.values["apiKey"] == "sk-cp-fixture")
      #expect(
        try WindowsStagedProviderConfig.encodeManual(provider: .minimax, record: saved).source
          == "api")
    }

    @Test("DeepSeek stages one ephemeral token account and no API key")
    func deepSeekTokenAccountTransport() throws {
      let canary = "fictitious-deepseek-staged-token"
      let set = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.deepSeek]?.credentialSet(id: "api-key"))
      guard case .stagedTokenAccount = set.secretTransport else {
        Issue.record("DeepSeek did not declare staged token-account transport")
        return
      }
      let record = WindowsProviderCredentialRecord(
        provider: .deepSeek,
        credentialSetID: set.id,
        values: ["apiKey": canary])
      let staged = try WindowsStagedProviderConfig.encodeManual(provider: .deepSeek, record: record)
      let second = try WindowsStagedProviderConfig.encodeManual(provider: .deepSeek, record: record)
      let root = try #require(JSONSerialization.jsonObject(with: staged.data) as? [String: Any])
      let provider = try #require((root["providers"] as? [[String: Any]])?.first)
      let tokenAccounts = try #require(provider["tokenAccounts"] as? [String: Any])
      let accounts = try #require(tokenAccounts["accounts"] as? [[String: Any]])
      let account = try #require(accounts.first)

      #expect(staged.source == "api")
      #expect(provider["apiKey"] == nil)
      #expect(accounts.count == 1)
      #expect(Foundation.UUID(uuidString: try #require(account["id"] as? String)) != nil)
      #expect((account["label"] as? String)?.isEmpty == true)
      #expect(account["token"] as? String == canary)
      #expect(account["addedAt"] as? Double == 0)
      #expect(account["lastUsed"] is NSNull)
      #expect(account["externalIdentifier"] == nil)
      #expect(tokenAccounts["version"] as? Int == 1)
      #expect(tokenAccounts["activeIndex"] as? Int == 0)
      #expect(staged.data.range(of: Data("DEEPSEEK_API_KEY".utf8)) == nil)
      let tokenAccountProviders: [WindowsProviderID] =
        WindowsProviderConfigurationCatalog.schemas
        .flatMap { schema in
          schema.credentialSets.map { (schema.provider, $0.secretTransport) }
        }
        .compactMap { provider, transport in
          if case .stagedTokenAccount = transport { return provider }
          return nil
        }
      #expect(tokenAccountProviders == [.deepSeek])
      let secondRoot = try #require(
        JSONSerialization.jsonObject(with: second.data) as? [String: Any])
      let secondProvider = try #require((secondRoot["providers"] as? [[String: Any]])?.first)
      let secondTokenAccounts = try #require(secondProvider["tokenAccounts"] as? [String: Any])
      let secondAccounts = try #require(secondTokenAccounts["accounts"] as? [[String: Any]])
      #expect(secondAccounts.first?["id"] as? String != account["id"] as? String)

      let invocation = WindowsCanonicalCLIInvocation.stagedWSL(
        distribution: "Ubuntu",
        launcherPath: "/opt/codexbar/CodexBarStagingLauncher",
        providerID: "deepseek",
        source: staged.source,
        config: staged.data,
        credentialPath: set.label,
        windowsDirectory: "C:\\Windows")
      #expect(!invocation.arguments.contains(where: { $0.contains(canary) }))
      #expect(!invocation.description.contains(canary))
      #expect(!invocation.debugDescription.contains(canary))

      let payload =
        #"""
        [{
          "provider":"deepseek",
          "account":"",
          "source":"api",
          "usage":{
            "primary":{
              "usedPercent":12,
              "windowMinutes":300,
              "resetsAt":null,
              "resetDescription":null
            },
            "secondary":null,
            "tertiary":null,
            "extraRateWindows":[],
            "updatedAt":"2026-09-03T00:00:00Z",
            "identity":null
          },
          "credits":null,
          "error":null
        }]
        """#
      let snapshot = try WindowsCanonicalCLIProviderClient.decode(
        data: Data(payload.utf8),
        requestedProvider: .deepSeek,
        source: WindowsProviderSourcePresentation(
          distributionLabel: "Ubuntu",
          kind: .manual("API key"),
          isResolved: true))
      let row = try #require(
        WindowsDashboardPresentation.make(
          snapshots: [snapshot],
          refreshedAt: Date(timeIntervalSince1970: 0),
          providers: [.deepSeek]
        )
        .rows.first)
      #expect(snapshot.accountText == nil)
      #expect(row.accountText.isEmpty)
      #expect(!row.accessibilityText.contains("ephemeral"))
    }
  }
#endif
