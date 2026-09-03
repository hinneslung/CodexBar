import Foundation

/// A stable provider identifier used by the Windows application.
///
/// This is intentionally an open raw-value type instead of an enum so a configuration
/// written by a newer CodexBar can still be decoded by an older build.
struct WindowsProviderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.rawValue)
  }

  var description: String { self.rawValue }
}

struct WindowsProviderCatalogEntry: Hashable, Sendable {
  let id: WindowsProviderID
  let displayName: String
  let isLiveOnWindows: Bool
  let searchAliases: [String]

  init(
    id: WindowsProviderID,
    displayName: String,
    isLiveOnWindows: Bool,
    searchAliases: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.isLiveOnWindows = isLiveOnWindows
    self.searchAliases = searchAliases
  }
}

/// Windows' upstream-derived provider registry. Keep this in the same order as
/// `UsageProvider` so new configurations and settings screens have deterministic order.
enum WindowsProviderCatalog {
  static let entries: [WindowsProviderCatalogEntry] = [
    .init(
      id: .codex,
      displayName: "Codex",
      isLiveOnWindows: true,
      searchAliases: ["ChatGPT"]),
    .init(id: .openai, displayName: "OpenAI", isLiveOnWindows: false),
    .init(id: .azureOpenAI, displayName: "Azure OpenAI", isLiveOnWindows: false),
    .init(id: .claude, displayName: "Claude", isLiveOnWindows: true),
    .init(id: .clinePass, displayName: "ClinePass", isLiveOnWindows: false),
    .init(id: .cursor, displayName: "Cursor", isLiveOnWindows: false),
    .init(id: .openCode, displayName: "OpenCode", isLiveOnWindows: false),
    .init(id: .openCodeGo, displayName: "OpenCode Go", isLiveOnWindows: true),
    .init(id: .alibaba, displayName: "Alibaba Coding Plan", isLiveOnWindows: false),
    .init(id: .alibabaTokenPlan, displayName: "Alibaba Token Plan", isLiveOnWindows: false),
    .init(id: .qwenCloud, displayName: "Qwen Cloud", isLiveOnWindows: false),
    .init(
      id: .factory,
      displayName: "Droid (Factory)",
      isLiveOnWindows: false,
      searchAliases: ["Droid", "Factory"]),
    .init(id: .fireworks, displayName: "Fireworks", isLiveOnWindows: false),
    .init(id: .gemini, displayName: "Gemini", isLiveOnWindows: false),
    .init(id: .antigravity, displayName: "Antigravity", isLiveOnWindows: false),
    .init(
      id: .copilot,
      displayName: "Copilot",
      isLiveOnWindows: true,
      searchAliases: ["GitHub Copilot"]),
    .init(id: .devin, displayName: "Devin", isLiveOnWindows: false),
    .init(
      id: .zai,
      displayName: "z.ai",
      isLiveOnWindows: false,
      searchAliases: ["Z AI"]),
    .init(id: .minimax, displayName: "MiniMax", isLiveOnWindows: false),
    .init(id: .manus, displayName: "Manus", isLiveOnWindows: false),
    .init(id: .kimi, displayName: "Kimi", isLiveOnWindows: false),
    .init(id: .kilo, displayName: "Kilo", isLiveOnWindows: false),
    .init(id: .kiro, displayName: "Kiro", isLiveOnWindows: false),
    .init(id: .vertexAI, displayName: "Vertex AI", isLiveOnWindows: false),
    .init(id: .augment, displayName: "Augment", isLiveOnWindows: false),
    .init(id: .jetBrains, displayName: "JetBrains AI", isLiveOnWindows: false),
    .init(id: .moonshot, displayName: "Moonshot", isLiveOnWindows: false),
    .init(id: .amp, displayName: "Amp", isLiveOnWindows: false),
    .init(id: .t3Chat, displayName: "T3 Chat", isLiveOnWindows: false),
    .init(id: .ollama, displayName: "Ollama", isLiveOnWindows: false),
    .init(id: .synthetic, displayName: "Synthetic", isLiveOnWindows: false),
    .init(id: .openRouter, displayName: "OpenRouter", isLiveOnWindows: false),
    .init(id: .elevenLabs, displayName: "ElevenLabs", isLiveOnWindows: false),
    .init(id: .warp, displayName: "Warp", isLiveOnWindows: false),
    .init(id: .windsurf, displayName: "Windsurf", isLiveOnWindows: false),
    .init(id: .zed, displayName: "Zed", isLiveOnWindows: false),
    .init(id: .perplexity, displayName: "Perplexity", isLiveOnWindows: false),
    .init(id: .mimo, displayName: "Xiaomi MiMo", isLiveOnWindows: false),
    .init(id: .doubao, displayName: "Doubao", isLiveOnWindows: false),
    .init(id: .sakana, displayName: "Sakana AI", isLiveOnWindows: false),
    .init(id: .abacus, displayName: "Abacus AI", isLiveOnWindows: false),
    .init(id: .mistral, displayName: "Mistral", isLiveOnWindows: false),
    .init(id: .deepSeek, displayName: "DeepSeek", isLiveOnWindows: false),
    .init(id: .deepInfra, displayName: "DeepInfra", isLiveOnWindows: false),
    .init(id: .codebuff, displayName: "Codebuff", isLiveOnWindows: false),
    .init(id: .crof, displayName: "Crof", isLiveOnWindows: false),
    .init(id: .venice, displayName: "Venice", isLiveOnWindows: false),
    .init(id: .commandCode, displayName: "Command Code", isLiveOnWindows: false),
    .init(id: .qoder, displayName: "Qoder", isLiveOnWindows: false),
    .init(id: .stepFun, displayName: "StepFun", isLiveOnWindows: false),
    .init(id: .bedrock, displayName: "AWS Bedrock", isLiveOnWindows: false),
    .init(id: .grok, displayName: "Grok", isLiveOnWindows: false),
    .init(
      id: .groq,
      displayName: "GroqCloud",
      isLiveOnWindows: false,
      searchAliases: ["Groq"]),
    .init(id: .llmProxy, displayName: "LLM Proxy", isLiveOnWindows: false),
    .init(id: .liteLLM, displayName: "LiteLLM", isLiveOnWindows: false),
    .init(id: .deepgram, displayName: "Deepgram", isLiveOnWindows: false),
    .init(id: .poe, displayName: "Poe", isLiveOnWindows: true),
    .init(id: .chutes, displayName: "Chutes", isLiveOnWindows: false),
    .init(id: .neuralwatt, displayName: "Neuralwatt", isLiveOnWindows: false),
    .init(id: .clawRouter, displayName: "ClawRouter", isLiveOnWindows: false),
    .init(id: .longCat, displayName: "LongCat", isLiveOnWindows: false),
    .init(id: .sub2API, displayName: "Sub2API", isLiveOnWindows: false),
    .init(id: .wayfinder, displayName: "Wayfinder", isLiveOnWindows: false),
    .init(id: .zenMux, displayName: "ZenMux", isLiveOnWindows: false),
    .init(id: .aiAnd, displayName: "ai&", isLiveOnWindows: false),
    .init(id: .zoomMate, displayName: "ZoomMate", isLiveOnWindows: false),
    .init(id: .xAI, displayName: "xAI", isLiveOnWindows: false),
    .init(id: .notion, displayName: "Notion AI", isLiveOnWindows: false),
    .init(id: .ibmBob, displayName: "IBM Bob", isLiveOnWindows: false),
  ]

  static let byID: [WindowsProviderID: WindowsProviderCatalogEntry] =
    Dictionary(uniqueKeysWithValues: Self.entries.map { ($0.id, $0) })
}

enum WindowsProviderSettingsSearch {
  private static let locale = Locale(identifier: "en_US_POSIX")

  static func filteredDisabledProviders(
    in configuration: WindowsAppConfiguration,
    query: String
  ) -> [WindowsProviderConfiguration] {
    configuration.disabledProviders.filter { self.matches(provider: $0.id, query: query) }
  }

  static func matches(provider: WindowsProviderID, query: String) -> Bool {
    let needle = self.normalized(query)
    guard !needle.isEmpty else { return true }
    guard let entry = WindowsProviderCatalog.byID[provider] else {
      return self.normalized(provider.rawValue).contains(needle)
    }
    let values = [entry.displayName, provider.rawValue, provider.cliName] + entry.searchAliases
    return values.contains { self.normalized($0).contains(needle) }
  }

  static func alphabeticalOrder(
    _ lhs: WindowsProviderConfiguration,
    _ rhs: WindowsProviderConfiguration
  ) -> Bool {
    let leftName = self.normalized(lhs.id.displayName)
    let rightName = self.normalized(rhs.id.displayName)
    if leftName != rightName { return leftName < rightName }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  private static func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: self.locale
      )
      .lowercased(with: self.locale)
  }
}

extension WindowsProviderID {
  /// Providers enabled in a fresh Windows configuration. This is presentation policy only;
  /// every provider uses the same canonical CLI runtime.
  static var initiallyEnabledProviders: [Self] {
    [.codex, .claude]
  }

  /// Providers with a working Windows data path. Availability is independent from first-run policy.
  static var liveProviders: [Self] {
    [.codex, .claude, .poe, .copilot, .openCodeGo]
  }

  var displayName: String {
    WindowsProviderCatalog.byID[self]?.displayName ?? self.rawValue
  }

  /// Canonical name accepted by the unchanged upstream CLI. Most match the stable provider ID;
  /// the exceptions are pinned here so every Windows source uses the same argument mapping.
  var cliName: String {
    switch self {
    case .abacus: "abacusai"
    case .alibaba: "alibaba-coding-plan"
    case .alibabaTokenPlan: "alibaba-token-plan"
    case .azureOpenAI: "azure-openai"
    case .groq: "groqcloud"
    case .qwenCloud: "qwen-cloud"
    default: self.rawValue
    }
  }

  static let githubCopilot = Self.copilot
  static let codex = Self(rawValue: "codex")
  static let openai = Self(rawValue: "openai")
  static let azureOpenAI = Self(rawValue: "azureopenai")
  static let claude = Self(rawValue: "claude")
  static let clinePass = Self(rawValue: "clinepass")
  static let cursor = Self(rawValue: "cursor")
  static let openCode = Self(rawValue: "opencode")
  static let openCodeGo = Self(rawValue: "opencodego")
  static let alibaba = Self(rawValue: "alibaba")
  static let alibabaTokenPlan = Self(rawValue: "alibabatokenplan")
  static let qwenCloud = Self(rawValue: "qwencloud")
  static let factory = Self(rawValue: "factory")
  static let gemini = Self(rawValue: "gemini")
  static let antigravity = Self(rawValue: "antigravity")
  static let copilot = Self(rawValue: "copilot")
  static let devin = Self(rawValue: "devin")
  static let zai = Self(rawValue: "zai")
  static let minimax = Self(rawValue: "minimax")
  static let manus = Self(rawValue: "manus")
  static let kimi = Self(rawValue: "kimi")
  static let kilo = Self(rawValue: "kilo")
  static let kiro = Self(rawValue: "kiro")
  static let vertexAI = Self(rawValue: "vertexai")
  static let augment = Self(rawValue: "augment")
  static let jetBrains = Self(rawValue: "jetbrains")
  static let moonshot = Self(rawValue: "moonshot")
  static let amp = Self(rawValue: "amp")
  static let t3Chat = Self(rawValue: "t3chat")
  static let ollama = Self(rawValue: "ollama")
  static let synthetic = Self(rawValue: "synthetic")
  static let warp = Self(rawValue: "warp")
  static let openRouter = Self(rawValue: "openrouter")
  static let elevenLabs = Self(rawValue: "elevenlabs")
  static let windsurf = Self(rawValue: "windsurf")
  static let zed = Self(rawValue: "zed")
  static let perplexity = Self(rawValue: "perplexity")
  static let mimo = Self(rawValue: "mimo")
  static let doubao = Self(rawValue: "doubao")
  static let sakana = Self(rawValue: "sakana")
  static let abacus = Self(rawValue: "abacus")
  static let mistral = Self(rawValue: "mistral")
  static let deepSeek = Self(rawValue: "deepseek")
  static let fireworks = Self(rawValue: "fireworks")
  static let deepInfra = Self(rawValue: "deepinfra")
  static let codebuff = Self(rawValue: "codebuff")
  static let crof = Self(rawValue: "crof")
  static let venice = Self(rawValue: "venice")
  static let commandCode = Self(rawValue: "commandcode")
  static let qoder = Self(rawValue: "qoder")
  static let stepFun = Self(rawValue: "stepfun")
  static let bedrock = Self(rawValue: "bedrock")
  static let grok = Self(rawValue: "grok")
  static let groq = Self(rawValue: "groq")
  static let llmProxy = Self(rawValue: "llmproxy")
  static let liteLLM = Self(rawValue: "litellm")
  static let deepgram = Self(rawValue: "deepgram")
  static let poe = Self(rawValue: "poe")
  static let chutes = Self(rawValue: "chutes")
  static let neuralwatt = Self(rawValue: "neuralwatt")
  static let clawRouter = Self(rawValue: "clawrouter")
  static let longCat = Self(rawValue: "longcat")
  static let sub2API = Self(rawValue: "sub2api")
  static let wayfinder = Self(rawValue: "wayfinder")
  static let zenMux = Self(rawValue: "zenmux")
  static let aiAnd = Self(rawValue: "aiand")
  static let zoomMate = Self(rawValue: "zoommate")
  static let xAI = Self(rawValue: "xai")
  static let notion = Self(rawValue: "notion")
  static let ibmBob = Self(rawValue: "ibmbob")
}
