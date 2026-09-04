import Foundation
import XCTest

@testable import CodexBarWindows

final class WindowsAppConfigurationTests: XCTestCase {
  func test_catalogMatchesCurrentUpstreamProviderIDsAndNames() {
    let expected: [(String, String)] = [
      ("codex", "Codex"), ("openai", "OpenAI"), ("azureopenai", "Azure OpenAI"),
      ("claude", "Claude"), ("clinepass", "ClinePass"), ("cursor", "Cursor"),
      ("opencode", "OpenCode"), ("opencodego", "OpenCode Go"),
      ("alibaba", "Alibaba Coding Plan"), ("alibabatokenplan", "Alibaba Token Plan"),
      ("qwencloud", "Qwen Cloud"), ("factory", "Droid (Factory)"), ("fireworks", "Fireworks"),
      ("gemini", "Gemini"),
      ("antigravity", "Antigravity"), ("copilot", "Copilot"), ("devin", "Devin"),
      ("zai", "z.ai"), ("minimax", "MiniMax"), ("manus", "Manus"), ("kimi", "Kimi"),
      ("kilo", "Kilo"), ("kiro", "Kiro"), ("vertexai", "Vertex AI"), ("augment", "Augment"),
      ("jetbrains", "JetBrains AI"), ("moonshot", "Moonshot"), ("amp", "Amp"),
      ("t3chat", "T3 Chat"), ("ollama", "Ollama"), ("synthetic", "Synthetic"),
      ("openrouter", "OpenRouter"), ("elevenlabs", "ElevenLabs"), ("warp", "Warp"),
      ("windsurf", "Windsurf"),
      ("zed", "Zed"), ("perplexity", "Perplexity"), ("mimo", "Xiaomi MiMo"),
      ("doubao", "Doubao"), ("sakana", "Sakana AI"), ("abacus", "Abacus AI"),
      ("mistral", "Mistral"), ("deepseek", "DeepSeek"),
      ("deepinfra", "DeepInfra"), ("codebuff", "Codebuff"), ("crof", "Crof"),
      ("venice", "Venice"), ("commandcode", "Command Code"), ("qoder", "Qoder"),
      ("stepfun", "StepFun"), ("bedrock", "AWS Bedrock"), ("grok", "Grok"),
      ("groq", "GroqCloud"), ("llmproxy", "LLM Proxy"), ("litellm", "LiteLLM"),
      ("deepgram", "Deepgram"), ("poe", "Poe"), ("chutes", "Chutes"),
      ("neuralwatt", "Neuralwatt"), ("clawrouter", "ClawRouter"), ("longcat", "LongCat"),
      ("sub2api", "Sub2API"), ("wayfinder", "Wayfinder"), ("zenmux", "ZenMux"),
      ("aiand", "ai&"), ("zoommate", "ZoomMate"), ("xai", "xAI"),
      ("notion", "Notion AI"), ("ibmbob", "IBM Bob"),
    ]

    XCTAssertEqual(WindowsProviderCatalog.entries.map { $0.id.rawValue }, expected.map(\.0))
    XCTAssertEqual(WindowsProviderCatalog.entries.map(\.displayName), expected.map(\.1))
    XCTAssertEqual(WindowsProviderCatalog.byID.count, expected.count)
    XCTAssertEqual(
      Set(WindowsProviderID.supportedProviders),
      Set(WindowsProviderCatalog.entries.map(\.id))
        .subtracting(WindowsProviderConfigurationCatalog.unavailableProviderIDs))
    XCTAssertEqual(WindowsProviderID.supportedProviders.count, 65)
  }

  func test_defaultsEnableOnlyCodexAndClaude() {
    let enabled = WindowsAppConfiguration.defaults.providers.filter(\.enabled).map(\.id)
    XCTAssertEqual(enabled, [.codex, .claude])
    XCTAssertEqual(WindowsAppConfiguration.defaults.refreshIntervalMinutes, 5)
    XCTAssertFalse(WindowsAppConfiguration.defaults.runAtStartup)
  }

  func test_defaultDisabledProvidersAreAlphabetical() {
    let disabled = WindowsAppConfiguration.defaults.disabledProviders
    let expected = disabled.sorted(by: WindowsProviderSettingsSearch.alphabeticalOrder)
    XCTAssertEqual(disabled.map(\.id), expected.map(\.id))
  }

  func test_cliNamesMatchCanonicalUpstreamArguments() {
    let exceptions: [WindowsProviderID: String] = [
      .abacus: "abacusai",
      .alibaba: "alibaba-coding-plan",
      .alibabaTokenPlan: "alibaba-token-plan",
      .azureOpenAI: "azure-openai",
      .groq: "groqcloud",
      .qwenCloud: "qwen-cloud",
    ]
    for entry in WindowsProviderCatalog.entries {
      XCTAssertEqual(entry.id.cliName, exceptions[entry.id] ?? entry.id.rawValue)
    }
  }

  func test_forwardCompatibleDecodeUsesDefaultsAndPreservesUnknownProviderAndSource() throws {
    let data = Data(
      """
      {
        "schemaVersion": 42,
        "futureTopLevelField": true,
        "providers": [{
          "id": "future-provider",
          "sourceMode": "future-source",
          "futureProviderField": "ignored"
        }]
      }
      """.utf8)

    let configuration = try JSONDecoder().decode(WindowsAppConfiguration.self, from: data)
    let provider = try XCTUnwrap(configuration.providers.first)
    XCTAssertEqual(configuration.schemaVersion, 42)
    XCTAssertFalse(configuration.usageBarsShowUsed)
    XCTAssertEqual(configuration.refreshIntervalMinutes, 5)
    XCTAssertFalse(configuration.runAtStartup)
    XCTAssertEqual(provider.id.rawValue, "future-provider")
    XCTAssertEqual(provider.sourceMode.rawValue, "future-source")
    XCTAssertFalse(provider.enabled)
    XCTAssertEqual(provider.order, .max)
  }

  func test_mergeAppendsCatalogWithoutDiscardingUnknownProviders() {
    let unknown = WindowsProviderConfiguration(
      id: .init(rawValue: "future-provider"),
      enabled: true,
      order: 0)
    let merged = WindowsAppConfiguration(schemaVersion: 9, providers: [unknown])
      .mergingCatalogDefaults()

    XCTAssertEqual(merged.schemaVersion, 9)
    XCTAssertEqual(merged.providers.first?.id.rawValue, "future-provider")
    XCTAssertEqual(merged.providers.count, WindowsProviderCatalog.entries.count + 1)

    let upgraded = WindowsAppConfiguration(schemaVersion: 2, providers: [unknown])
      .mergingCatalogDefaults()
    XCTAssertEqual(upgraded.schemaVersion, WindowsAppConfiguration.currentSchemaVersion)
  }

  func test_schemaSixMigrationPreservesEnabledOrderAndAlphabetizesDisabledProviders() {
    let migrated = WindowsAppConfiguration(
      schemaVersion: 6,
      providers: [
        .init(id: .claude, enabled: true, order: 0),
        .init(id: .codex, enabled: true, order: 1),
        .init(id: .poe, enabled: false, order: 2),
        .init(id: .copilot, enabled: false, order: 3),
      ]
    ).mergingCatalogDefaults()

    XCTAssertEqual(migrated.schemaVersion, WindowsAppConfiguration.currentSchemaVersion)
    XCTAssertEqual(migrated.enabledProviders.map(\.id), [.claude, .codex])
    XCTAssertEqual(
      migrated.disabledProviders.map(\.id),
      migrated.disabledProviders.sorted(by: WindowsProviderSettingsSearch.alphabeticalOrder).map(
        \.id))
  }

  func test_enablingProviderMovesItToBottomOfEnabledSection() {
    var configuration = WindowsAppConfiguration(providers: [
      .init(id: .codex, enabled: true, order: 0),
      .init(id: .claude, enabled: true, order: 1),
      .init(id: .poe, enabled: false, order: 2),
      .init(id: .copilot, enabled: false, order: 3),
    ])

    XCTAssertTrue(configuration.setProviderEnabled(.poe, enabled: true))
    XCTAssertEqual(configuration.enabledProviders.map(\.id), [.codex, .claude, .poe])
    XCTAssertEqual(configuration.disabledProviders.map(\.id), [.copilot])
    XCTAssertEqual(configuration.orderedProviders.map(\.order), [0, 1, 2, 3])
  }

  func test_disablingProviderMovesItToTopOfDisabledSection() {
    var configuration = WindowsAppConfiguration(providers: [
      .init(id: .codex, enabled: true, order: 0),
      .init(id: .claude, enabled: true, order: 1),
      .init(id: .poe, enabled: true, order: 2),
      .init(id: .copilot, enabled: false, order: 3),
    ])

    XCTAssertTrue(configuration.setProviderEnabled(.claude, enabled: false))
    XCTAssertEqual(configuration.enabledProviders.map(\.id), [.codex, .poe])
    XCTAssertEqual(configuration.disabledProviders.map(\.id), [.claude, .copilot])
    XCTAssertEqual(configuration.orderedProviders.map(\.order), [0, 1, 2, 3])
  }

  func test_storeResolvesLocalAppDataAndRoundTripsAtomically() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBarWindowsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WindowsConfigurationStore(environment: ["LOCALAPPDATA": root.path])
    XCTAssertEqual(
      store.fileURL,
      root.appendingPathComponent("CodexBar", isDirectory: true)
        .appendingPathComponent("config.json", isDirectory: false))

    var configuration = WindowsAppConfiguration.defaults
    configuration.usageBarsShowUsed = true
    configuration.refreshIntervalMinutes = 17
    configuration.runAtStartup = true
    configuration.providers[0].sourceMode = .wsl
    configuration.providers[0].wslDistro = "Ubuntu-24.04"
    try store.save(configuration)

    XCTAssertEqual(try store.load(), configuration)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  func test_storePersistsOneTimeDisabledOrderingMigration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CodexBarWindowsMigrationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WindowsConfigurationStore(
      fileURL: root.appendingPathComponent("CodexBar", isDirectory: true)
        .appendingPathComponent("config.json", isDirectory: false))
    let legacy = WindowsAppConfiguration(
      schemaVersion: 6,
      providers: [
        .init(id: .codex, enabled: true, order: 0),
        .init(id: .poe, enabled: false, order: 1),
        .init(id: .copilot, enabled: false, order: 2),
      ])
    try store.save(legacy)

    let migrated = try store.load()
    let persisted = try JSONDecoder().decode(
      WindowsAppConfiguration.self,
      from: Data(contentsOf: store.fileURL))
    XCTAssertEqual(persisted, migrated)
    XCTAssertEqual(persisted.schemaVersion, WindowsAppConfiguration.currentSchemaVersion)
  }

  func test_disabledProviderSearchMatchesNameIDCLINameAndAliases() {
    XCTAssertTrue(WindowsProviderSettingsSearch.matches(provider: .openRouter, query: "router"))
    XCTAssertTrue(
      WindowsProviderSettingsSearch.matches(provider: .azureOpenAI, query: "azure-openai"))
    XCTAssertTrue(WindowsProviderSettingsSearch.matches(provider: .abacus, query: "abacusai"))
    XCTAssertTrue(WindowsProviderSettingsSearch.matches(provider: .copilot, query: "GitHub"))
    XCTAssertTrue(WindowsProviderSettingsSearch.matches(provider: .claude, query: "Cláude"))
    XCTAssertFalse(WindowsProviderSettingsSearch.matches(provider: .claude, query: "copilot"))
  }

  func test_disabledProviderSearchFiltersWithoutMutatingOrder() {
    let configuration = WindowsAppConfiguration.defaults
    let before = configuration
    let results = WindowsProviderSettingsSearch.filteredDisabledProviders(
      in: configuration,
      query: "open")

    XCTAssertEqual(
      results.map(\.id),
      [.azureOpenAI, .openai, .openCode, .openCodeGo, .openRouter])
    XCTAssertEqual(configuration, before)
    XCTAssertEqual(
      WindowsProviderSettingsSearch.filteredDisabledProviders(in: configuration, query: "   "),
      configuration.disabledProviders)
    XCTAssertTrue(
      WindowsProviderSettingsSearch.filteredDisabledProviders(
        in: configuration,
        query: "no-provider-can-match-this"
      ).isEmpty)
  }

  func test_refreshIntervalParsingAndDecodeStayWithinSupportedRange() throws {
    XCTAssertEqual(WindowsAppConfiguration.parsedRefreshIntervalMinutes(" 15 "), 15)
    XCTAssertNil(WindowsAppConfiguration.parsedRefreshIntervalMinutes("0"))
    XCTAssertNil(WindowsAppConfiguration.parsedRefreshIntervalMinutes("1441"))
    XCTAssertNil(WindowsAppConfiguration.parsedRefreshIntervalMinutes("soon"))

    let tooSmall = try JSONDecoder().decode(
      WindowsAppConfiguration.self,
      from: Data("{\"refreshIntervalMinutes\":0}".utf8))
    let tooLarge = try JSONDecoder().decode(
      WindowsAppConfiguration.self,
      from: Data("{\"refreshIntervalMinutes\":9999}".utf8))
    XCTAssertEqual(tooSmall.refreshIntervalMinutes, 1)
    XCTAssertEqual(tooLarge.refreshIntervalMinutes, 1440)
  }

  func test_missingFileLoadsDefaultsAndMissingLocalAppDataFails() throws {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("config.json")
    XCTAssertEqual(try WindowsConfigurationStore(fileURL: missingURL).load(), .defaults)
    XCTAssertThrowsError(try WindowsConfigurationStore(environment: [:])) { error in
      XCTAssertEqual(error as? WindowsConfigurationStoreError, .localAppDataUnavailable)
    }
  }

  func testDescriptionsAndDebugOutputNeverExposeConfiguredValues() throws {
    let marker = "DO-NOT-LEAK-THIS-VALUE"
    let provider = WindowsProviderConfiguration(
      id: .codex,
      enabled: true,
      order: 0,
      sourceMode: .wsl,
      wslDistro: marker)
    let configuration = WindowsAppConfiguration(providers: [provider])

    for output in [
      provider.description, provider.debugDescription, String(describing: configuration),
      String(reflecting: configuration),
    ] {
      XCTAssertFalse(output.contains(marker))
    }

    let attemptedSecret = Data(
      """
      {"id":"azureopenai","apiKey":"\(marker)","cookie":"\(marker)","manual":{"password":"\(marker)"},\
      "companionValues":{"apiKey":"\(marker)","unknown":"\(marker)",\
      "enterpriseHost":"https://resource.example.test"}}
      """.utf8)
    let decoded = try JSONDecoder().decode(WindowsProviderConfiguration.self, from: attemptedSecret)
    let encoded = try JSONEncoder().encode(decoded)
    let encodedText = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
    XCTAssertFalse(encodedText.contains(marker))
    XCTAssertEqual(decoded.companionValues, ["enterpriseHost": "https://resource.example.test"])
  }
}
