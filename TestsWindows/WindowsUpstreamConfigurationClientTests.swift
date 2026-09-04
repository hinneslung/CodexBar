#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  import WinSDK
  @testable import CodexBarWindows

  @Suite("Windows manual provider configuration")
  struct WindowsUpstreamConfigurationClientTests {
    @Test
    func `manual provider methods and canonical IDs stay pinned`() throws {
      let actual = WindowsProviderConfigurationCatalog.schemas
        .map { "\($0.provider.rawValue)=\($0.cliName)" }
        .sorted()
      let expected = [
        "aiand=aiand", "alibaba=alibaba-coding-plan",
        "alibabatokenplan=alibaba-token-plan", "amp=amp",
        "azureopenai=azure-openai", "chutes=chutes", "claude=claude",
        "clawrouter=clawrouter", "clinepass=clinepass", "codebuff=codebuff",
        "commandcode=commandcode", "copilot=copilot", "crof=crof",
        "cursor=cursor", "deepgram=deepgram", "deepinfra=deepinfra",
        "deepseek=deepseek", "doubao=doubao", "elevenlabs=elevenlabs", "factory=factory",
        "fireworks=fireworks", "grok=grok", "groq=groqcloud", "ibmbob=ibmbob",
        "kilo=kilo", "kimi=kimi", "litellm=litellm", "llmproxy=llmproxy",
        "longcat=longcat", "manus=manus", "mimo=mimo", "minimax=minimax",
        "mistral=mistral", "moonshot=moonshot", "neuralwatt=neuralwatt",
        "notion=notion", "ollama=ollama", "openai=openai", "opencode=opencode",
        "opencodego=opencodego", "openrouter=openrouter", "perplexity=perplexity",
        "poe=poe", "qoder=qoder",
        "qwencloud=qwen-cloud", "sakana=sakana", "sub2api=sub2api",
        "stepfun=stepfun", "synthetic=synthetic", "t3chat=t3chat", "venice=venice",
        "warp=warp", "xai=xai", "zai=zai", "zenmux=zenmux", "zoommate=zoommate",
      ].sorted()
      #expect(actual == expected)

      let expectedManualAPIProviderIDs: Set = [
        "aiand", "alibaba", "amp", "azureopenai", "chutes", "claude", "clinepass", "codebuff",
        "clawrouter", "copilot", "crof", "deepgram", "deepinfra", "deepseek", "doubao",
        "elevenlabs", "factory", "fireworks", "groq", "ibmbob", "kilo", "kimi", "litellm",
        "llmproxy", "minimax", "moonshot", "neuralwatt", "ollama", "openai", "opencodego",
        "openrouter", "poe", "sub2api", "synthetic", "venice", "warp", "xai", "zai",
        "zenmux",
      ]
      #expect(
        Set(WindowsProviderConfigurationCatalog.manualAPIProviderIDs.map(\.rawValue))
          == expectedManualAPIProviderIDs)
      let actualManualAPIProviderIDs = Set(
        WindowsProviderConfigurationCatalog.schemas.compactMap { schema in
          schema.manualCredentialSets.contains(where: { $0.id == "api-key" })
            ? schema.provider.rawValue : nil
        })
      #expect(actualManualAPIProviderIDs == expectedManualAPIProviderIDs)
      let disabledManualAPIProviderIDs: Set = [
        "alibabatokenplan", "commandcode", "cursor", "grok", "qoder", "qwencloud", "sakana",
      ]
      #expect(
        Set(
          WindowsProviderConfigurationCatalog.schemas.compactMap { schema in
            guard schema.credentialSet(id: "api-key") == nil,
              schema.credentialSets.contains(where: { $0.id == "api-key" })
            else { return nil }
            return schema.provider.rawValue
          }) == disabledManualAPIProviderIDs)
      for providerID in disabledManualAPIProviderIDs {
        let provider = WindowsProviderID(rawValue: providerID)
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[provider])
        #expect(schema.credentialSet(id: "api-key") == nil)
        #expect(schema.credentialSets.first(where: { $0.id == "api-key" })?.acceptsOpenCode == true)
      }

      let routeGate = try String(
        contentsOf: Self.repositoryRoot
          .appendingPathComponent("TestsLinux/StagingLauncher/test_unchanged_cli_routes.sh"),
        encoding: .utf8)
      #expect(
        try Set(Self.shellArray(named: "manual_api_providers", in: routeGate))
          == expectedManualAPIProviderIDs)
      #expect(
        try Set(Self.shellArray(named: "expanded_api_providers", in: routeGate)) == [
          "neuralwatt", "elevenlabs", "warp", "clawrouter", "llmproxy", "litellm",
          "sub2api", "xai", "clinepass", "deepseek", "minimax",
        ])
      let catalogWebRoutes = Set(
        WindowsProviderConfigurationCatalog.schemas.flatMap { schema in
          schema.manualCredentialSets.compactMap { set -> String? in
            guard set.executionMode == .usage, set.source == "web" else { return nil }
            return "\(schema.provider.rawValue)|\(schema.cliName)|\(set.source)"
          }
        })
      #expect(
        try Set(Self.shellArray(named: "manual_web_routes", in: routeGate)) == catalogWebRoutes)
      let catalogDiagnosticRoutes = Set(
        WindowsProviderConfigurationCatalog.schemas.flatMap { schema in
          schema.manualCredentialSets.compactMap { set -> String? in
            guard set.executionMode == .diagnose else { return nil }
            return "\(schema.provider.rawValue)|\(schema.cliName)|\(set.source)"
          }
        })
      #expect(
        try Set(Self.shellArray(named: "diagnostic_web_routes", in: routeGate))
          == catalogDiagnosticRoutes)

      let expectedBridgeRoutes = Set(
        WindowsProviderCredentialBridge.defaultRules.compactMap { rule -> String? in
          guard let candidate = rule.candidates.first else { return nil }
          let additional = candidate.additionalEnvironment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
          return ([rule.provider.rawValue, candidate.secretEnvironmentKey] + additional)
            .joined(separator: "|")
        })
      #expect(
        try Set(Self.shellArray(named: "open_code_bridge_routes", in: routeGate))
          == expectedBridgeRoutes)
      for rule in WindowsProviderCredentialBridge.defaultRules {
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[rule.provider])
        #expect(schema.credentialSets.contains(where: { $0.source == "api" && $0.acceptsOpenCode }))
      }

      let openCodeGo = try #require(WindowsProviderConfigurationCatalog.byProvider[.openCodeGo])
      #expect(openCodeGo.credentialSets.map(\.id) == ["api-key", "browser-session"])
      let browser = try #require(openCodeGo.credentialSet(id: "browser-session"))
      #expect(browser.source == "web")
      #expect(browser.derivesManualCookieSource)
      #expect(browser.fields.map(\.storage) == [.cookieHeader, .workspaceID])
      #expect(WindowsProviderConfigurationCatalog.byProvider[.codex] == nil)

      let catalogProviders = Set(WindowsProviderCatalog.entries.map(\.id))
      let supportedProviders = Set(WindowsProviderConfigurationCatalog.schemas.map(\.provider))
        .union(WindowsProviderConfigurationCatalog.providerAppOrCLIProviderIDs)
      #expect(catalogProviders.count == 69)
      #expect(supportedProviders.count == 65)
      #expect(WindowsProviderConfigurationCatalog.manualAPIProviderIDs.count == 39)
      #expect(WindowsProviderCredentialBridge.defaultRules.count == 20)
      #expect(WindowsProviderConfigurationCatalog.providerAppOrCLIProviderIDs.count == 17)
      #expect(WindowsProviderConfigurationCatalog.unavailableProviderIDs.count == 4)

      let automaticDiagnosticProviders = Set(
        WindowsProviderConfigurationCatalog.schemas.compactMap { schema in
          schema.automaticExecutionMode == .diagnose ? schema.provider : nil
        })
      #expect(
        automaticDiagnosticProviders == [
          .longCat, .manus, .mistral, .notion, .openCode, .perplexity, .stepFun,
          .t3Chat, .mimo, .zoomMate,
        ])
    }

    @Test
    func `DPAPI vault round trips without plaintext persistence`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      let marker = "codexbar-dpapi-canary-\(Foundation.UUID().uuidString)"
      let record = try vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": marker])
      #expect(record.values["apiKey"] == marker)
      #expect(vault.contains(.poe))
      #expect(try vault.load(.poe)?.values["apiKey"] == marker)
      let replacement = "codexbar-dpapi-replacement-\(Foundation.UUID().uuidString)"
      try vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": replacement])
      #expect(try vault.load(.poe)?.values["apiKey"] == replacement)

      let ciphertext = try Data(
        contentsOf: vault.directoryURL.appendingPathComponent("poe.bin"))
      #expect(!String(decoding: ciphertext, as: UTF8.self).contains(marker))
      #expect(!record.description.contains(marker))
      #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))

      try vault.clear(.poe)
      try vault.clear(.poe)
      #expect(!vault.contains(.poe))
    }

    @Test
    func `vault rejects provider swaps and damaged ciphertext`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      try vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": "provider-swap-canary"])
      let poe = vault.directoryURL.appendingPathComponent("poe.bin")
      let other = vault.directoryURL.appendingPathComponent("openrouter.bin")
      let copied = WindowsWideString.withPointer(poe.path) { source in
        WindowsWideString.withPointer(other.path) { target in
          CopyFileW(source, target, false)
        }
      }
      #expect(copied)
      #expect(throws: WindowsProviderCredentialVaultError.corruptedCredential) {
        _ = try vault.load(.openRouter)
      }

      let handle = WindowsWideString.withPointer(poe.path) { path in
        CreateFileW(
          path,
          DWORD(GENERIC_WRITE),
          0,
          nil,
          DWORD(TRUNCATE_EXISTING),
          DWORD(FILE_ATTRIBUTE_NORMAL),
          nil)
      }
      let rawHandle = try #require(handle != INVALID_HANDLE_VALUE ? handle : nil)
      var damaged = [UInt8](arrayLiteral: 0, 1, 2, 3)
      var written: DWORD = 0
      #expect(
        damaged.withUnsafeMutableBytes {
          WriteFile(rawHandle, $0.baseAddress, DWORD($0.count), &written, nil)
        })
      #expect(written == 4)
      #expect(CloseHandle(rawHandle))
      #expect(throws: WindowsProviderCredentialVaultError.protectedDataUnavailable) {
        _ = try vault.load(.poe)
      }
    }

    @Test
    func `vault rejects oversized and newer schema ciphertext before use`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("Credentials")
      let vault = WindowsProviderCredentialVault(directoryURL: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("poe.bin")

      try Data(repeating: 0xA5, count: WindowsProviderCredentialVault.maximumCiphertextBytes + 1)
        .write(to: file)
      #expect(throws: WindowsProviderCredentialVaultError.corruptedCredential) {
        _ = try vault.load(.poe)
      }

      let newer = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": WindowsProviderCredentialRecord.currentSchemaVersion + 1,
        "providerID": "poe",
        "credentialSetID": "api-key",
        "revision": Foundation.UUID().uuidString.lowercased(),
        "values": ["apiKey": "newer-schema-canary"],
      ])
      try WindowsProviderCredentialVault.protect(newer).write(to: file)
      #expect(throws: WindowsProviderCredentialVaultError.corruptedCredential) {
        _ = try vault.load(.poe)
      }
    }

    @Test
    func `failed atomic replacement preserves the previous credential`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      try vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": "initial-atomic-canary"])
      let file = vault.directoryURL.appendingPathComponent("poe.bin")
      let handle = WindowsWideString.withPointer(file.path) { path in
        CreateFileW(
          path,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_ATTRIBUTE_NORMAL),
          nil)
      }
      let rawHandle = try #require(handle != INVALID_HANDLE_VALUE ? handle : nil)
      #expect(throws: WindowsProviderCredentialVaultError.storageFailed) {
        _ = try vault.save(
          provider: .poe,
          credentialSetID: "api-key",
          submittedValues: ["apiKey": "replacement-atomic-canary"])
      }
      #expect(CloseHandle(rawHandle))
      #expect(try vault.load(.poe)?.values["apiKey"] == "initial-atomic-canary")
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.directoryURL.path)
        .filter { $0.hasSuffix(".tmp") }
      #expect(leftovers.isEmpty)
    }

    @Test
    func `browser session becomes a minimal web config`() throws {
      let cookie = "auth=fixture-cookie-not-live; secondary=value"
      let record = WindowsProviderCredentialRecord(
        provider: .openCodeGo,
        credentialSetID: "browser-session",
        values: ["cookieHeader": cookie, "workspaceID": "wrk_fixture"])
      let staged = try WindowsStagedProviderConfig.encodeManual(
        provider: .openCodeGo,
        record: record)
      #expect(staged.source == "web")
      let json = try #require(JSONSerialization.jsonObject(with: staged.data) as? [String: Any])
      let providers = try #require(json["providers"] as? [[String: Any]])
      let provider = try #require(providers.first)
      #expect(provider["id"] as? String == "opencodego")
      #expect(provider["source"] as? String == "web")
      #expect(provider["cookieSource"] as? String == "manual")
      #expect(provider["workspaceID"] as? String == "wrk_fixture")
      #expect((provider["cookieHeader"] as? String)?.utf8.count == cookie.utf8.count)
      #expect(provider["apiKey"] == nil)
    }

    @Test
    func `browser cURL capture is reduced to the cookie header before protection`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      let capture = """
        curl 'https://opencode.ai/workspace' \\
          -H 'Accept: application/json' \\
          -H 'Cookie: theme=dark; auth=fixture-browser-cookie'
        """
      let record = try vault.save(
        provider: .openCodeGo,
        credentialSetID: "browser-session",
        submittedValues: ["cookieHeader": capture])
      #expect(record.values["cookieHeader"] == "theme=dark; auth=fixture-browser-cookie")
      #expect(!record.values["cookieHeader", default: ""].contains("curl"))
      let browser = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.openCodeGo]?
          .credentialSet(id: "browser-session"))
      let field = try #require(browser.fields.first)
      #expect(!field.accepts("curl https://opencode.ai -H 'Accept: application/json'"))
    }

    @Test
    func `OpenCode bridge staging contains no projected secret`() throws {
      let canary = "opencode-environment-secret-canary"
      let staged = try WindowsStagedProviderConfig.encodeBridge(provider: .poe)
      let text = String(decoding: staged, as: UTF8.self)
      #expect(!text.contains(canary))
      #expect(!text.contains("apiKey"))
      #expect(text.contains("\"source\":\"api\""))
    }

    @Test
    func `configuration client saves and clears only the app vault`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = WindowsProviderCredentialVault(
        directoryURL: root.appendingPathComponent("Credentials"))
      let client = WindowsProviderConfigurationClient(vault: vault)
      #expect(try client.status(provider: .poe).credentialSetID == nil)
      let saved = try client.save(
        provider: .poe,
        credentialSetID: "api-key",
        values: ["apiKey": "client-canary"])
      #expect(saved.credentialSetID == "api-key")
      #expect(saved.configuredFieldIDs == ["apiKey"])
      #expect(saved.companionValues.isEmpty)
      #expect(try client.clear(provider: .poe).credentialSetID == nil)
    }

    @Test
    func `configuration fails closed without the canonical credential vault`() {
      let client = WindowsProviderConfigurationClient(vault: nil)
      #expect(!client.contains(provider: .poe))
      #expect(throws: WindowsProviderConfigurationError.storageUnavailable) {
        _ = try client.status(provider: .poe)
      }
      #expect(throws: WindowsProviderConfigurationError.storageUnavailable) {
        _ = try client.save(
          provider: .poe,
          credentialSetID: "api-key",
          values: ["apiKey": "must-not-be-written"])
      }
      #expect(throws: WindowsProviderConfigurationError.storageUnavailable) {
        _ = try client.clear(provider: .poe)
      }
    }

    @Test
    func `damaged credentials remain explicitly clearable`() throws {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("Credentials")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("poe.bin"))
      let vault = WindowsProviderCredentialVault(
        directoryURL: directory)
      let client = WindowsProviderConfigurationClient(vault: vault)
      #expect(client.contains(provider: .poe))
      #expect(throws: WindowsProviderCredentialVaultError.protectedDataUnavailable) {
        _ = try client.status(provider: .poe)
      }
      #expect(try client.clear(provider: .poe).credentialSetID == nil)
      #expect(!client.contains(provider: .poe))
    }

    @Test
    func `companion validation mirrors unchanged provider readers`() throws {
      let cases: [(WindowsProviderID, String, [String], [String])] = [
        (
          .azureOpenAI, "enterpriseHost",
          ["resource.openai.azure.com", "https://resource.openai.azure.com"],
          ["http://resource.example.test", "https://user:pass@example.test"]
        ),
        (
          .liteLLM, "enterpriseHost",
          ["https://public.example.test", "http://localhost:4000"],
          ["http://public.example.test", "https://user@example.test"]
        ),
        (.xAI, "workspaceID", ["team-123", "a.b"], ["", ".", "..", "team/id"]),
      ]
      for (provider, fieldID, accepted, rejected) in cases {
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[provider])
        let field = try #require(schema.credentialSets.flatMap(\.fields).first { $0.id == fieldID })
        for value in accepted {
          #expect(field.accepts(value))
        }
        for value in rejected {
          #expect(!field.accepts(value))
        }
      }
    }

    private static func temporaryDirectory() -> URL {
      FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexBarCredentialTests-\(Foundation.UUID().uuidString)")
    }

    private static var repositoryRoot: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }

    private static func shellArray(named name: String, in script: String) throws -> [String] {
      let normalizedScript =
        script
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      let start = try #require(normalizedScript.range(of: "\(name)=(\n"))
      let end = try #require(
        normalizedScript.range(of: "\n)", range: start.upperBound..<normalizedScript.endIndex))
      return normalizedScript[start.upperBound..<end.lowerBound]
        .split(whereSeparator: \.isWhitespace)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
  }
#endif
