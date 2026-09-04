import Foundation

/// Projects an OpenCode credential into one upstream CodexBar CLI child process.
/// Credentials are never persisted or included in diagnostics.
struct WindowsProviderCredentialBridge: Sendable {
  static let wslOpenCodeDataHomeEnvironmentKey = "CODEXBAR_WSL_OPENCODE_DATA_HOME"

  enum CredentialKind: Sendable {
    case apiKey
    case oauthAccess
  }

  struct Candidate: Sendable {
    let authProviderID: String
    let credentialKind: CredentialKind
    let secretEnvironmentKey: String
    let additionalEnvironment: [String: String]

    init(
      _ authProviderID: String,
      kind: CredentialKind = .apiKey,
      secretEnvironmentKey: String,
      additionalEnvironment: [String: String] = [:]
    ) {
      self.authProviderID = authProviderID
      self.credentialKind = kind
      self.secretEnvironmentKey = secretEnvironmentKey
      self.additionalEnvironment = additionalEnvironment
    }
  }

  struct Rule: Sendable {
    let provider: WindowsProviderID
    let candidates: [Candidate]
  }

  enum BridgeError: LocalizedError, Equatable, Sendable {
    case invalidAuthFile
    case expiredCredential(String)

    var errorDescription: String? {
      switch self {
      case .invalidAuthFile:
        "OpenCode sign-in data could not be read. Sign in again with OpenCode, then try again."
      case .expiredCredential(let provider):
        "The OpenCode sign-in for \(provider) has expired. Sign in again with OpenCode, then try again."
      }
    }
  }

  typealias AuthDataLoader = @Sendable ([String: String]) throws -> Data?

  private struct AuthEntry: Decodable {
    let type: String
    let key: String?
    let access: String?
    let expires: Int64?
  }

  private let rules: [WindowsProviderID: Rule]
  private let authDataLoader: AuthDataLoader

  init(
    rules: [Rule] = Self.defaultRules,
    authDataLoader: @escaping AuthDataLoader = {
      try Self.loadSelectedWSLAuthData(environment: $0)
    }
  ) {
    self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.provider, $0) })
    self.authDataLoader = authDataLoader
  }

  func environmentOverrides(
    for provider: WindowsProviderID,
    base: [String: String]
  ) throws -> [String: String] {
    guard let rule = self.rules[provider], let data = try self.authDataLoader(base) else {
      return [:]
    }

    let entries: [String: AuthEntry]
    do {
      entries = try JSONDecoder().decode([String: AuthEntry].self, from: data)
    } catch {
      throw BridgeError.invalidAuthFile
    }

    for candidate in rule.candidates {
      guard let entry = entries[candidate.authProviderID] else { continue }
      guard let secret = try Self.secret(from: entry, for: candidate) else { continue }

      var overrides = candidate.additionalEnvironment
      overrides[candidate.secretEnvironmentKey] = secret
      overrides["WSLENV"] = Self.mergedWSLEnvironment(
        existing: Self.environmentValue(named: "WSLENV", in: base),
        adding: Array(overrides.keys))
      return overrides
    }
    return [:]
  }

  static func supports(_ provider: WindowsProviderID) -> Bool {
    Self.defaultRules.contains { $0.provider == provider }
  }

  static func mergedWSLEnvironment(existing: String?, adding keys: [String]) -> String {
    var entries =
      existing?
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    var names = Set(entries.map(Self.wslEnvironmentName).map { $0.lowercased() })
    for key in keys.sorted() where names.insert(key.lowercased()).inserted {
      entries.append(key)
    }
    return entries.joined(separator: ":")
  }

  static let defaultRules: [Rule] = [
    .init(provider: .aiAnd, candidates: [.init("aiand", secretEnvironmentKey: "AIAND_API_KEY")]),
    .init(
      provider: .alibaba,
      candidates: [
        .init(
          "alibaba-coding-plan",
          secretEnvironmentKey: "ALIBABA_CODING_PLAN_API_KEY")
      ]),
    .init(provider: .chutes, candidates: [.init("chutes", secretEnvironmentKey: "CHUTES_API_KEY")]),
    .init(
      provider: .clinePass, candidates: [.init("cline-pass", secretEnvironmentKey: "CLINE_API_KEY")]
    ),
    .init(provider: .crof, candidates: [.init("crof", secretEnvironmentKey: "CROF_API_KEY")]),
    .init(
      provider: .deepInfra,
      candidates: [.init("deepinfra", secretEnvironmentKey: "DEEPINFRA_API_KEY")]),
    .init(
      provider: .deepSeek, candidates: [.init("deepseek", secretEnvironmentKey: "DEEPSEEK_API_KEY")]
    ),
    .init(
      provider: .fireworks,
      candidates: [.init("fireworks-ai", secretEnvironmentKey: "FIREWORKS_API_KEY")]),
    .init(
      provider: .copilot,
      candidates: [
        .init("github-copilot", kind: .oauthAccess, secretEnvironmentKey: "COPILOT_API_TOKEN")
      ]),
    .init(provider: .kilo, candidates: [.init("kilo", secretEnvironmentKey: "KILO_API_KEY")]),
    .init(
      provider: .kimi,
      candidates: [.init("kimi-for-coding", secretEnvironmentKey: "KIMI_CODE_API_KEY")]),
    .init(
      provider: .minimax,
      candidates: [
        .init(
          "minimax-coding-plan",
          secretEnvironmentKey: "MINIMAX_API_KEY")
      ]),
    .init(
      provider: .moonshot,
      candidates: [
        .init(
          "moonshotai",
          secretEnvironmentKey: "MOONSHOT_API_KEY",
          additionalEnvironment: ["MOONSHOT_REGION": "international"]),
        .init(
          "moonshotai-cn",
          secretEnvironmentKey: "MOONSHOT_API_KEY",
          additionalEnvironment: ["MOONSHOT_REGION": "china"]),
      ]),
    .init(
      provider: .ollama, candidates: [.init("ollama-cloud", secretEnvironmentKey: "OLLAMA_API_KEY")]
    ),
    .init(
      provider: .openCodeGo,
      candidates: [.init("opencode-go", secretEnvironmentKey: "OPENCODE_API_KEY")]),
    .init(
      provider: .openRouter,
      candidates: [.init("openrouter", secretEnvironmentKey: "OPENROUTER_API_KEY")]),
    .init(
      provider: .poe,
      candidates: [
        .init("poe", secretEnvironmentKey: "POE_API_KEY"),
        .init("poe", kind: .oauthAccess, secretEnvironmentKey: "POE_API_KEY"),
      ]),
    .init(
      provider: .synthetic,
      candidates: [.init("synthetic", secretEnvironmentKey: "SYNTHETIC_API_KEY")]),
    .init(provider: .venice, candidates: [.init("venice", secretEnvironmentKey: "VENICE_API_KEY")]),
    .init(
      provider: .zai,
      candidates: [
        .init(
          "zai",
          secretEnvironmentKey: "Z_AI_API_KEY",
          additionalEnvironment: ["Z_AI_REGION": "global"]),
        .init(
          "zai-coding-plan",
          secretEnvironmentKey: "Z_AI_API_KEY",
          additionalEnvironment: ["Z_AI_REGION": "global"]),
        .init(
          "zhipuai",
          secretEnvironmentKey: "ZHIPU_API_KEY",
          additionalEnvironment: ["Z_AI_REGION": "bigmodel-cn"]),
        .init(
          "zhipuai-coding-plan",
          secretEnvironmentKey: "ZHIPU_API_KEY",
          additionalEnvironment: ["Z_AI_REGION": "bigmodel-cn"]),
      ]),
  ]

  private static func secret(from entry: AuthEntry, for candidate: Candidate) throws -> String? {
    switch candidate.credentialKind {
    case .apiKey:
      guard entry.type.caseInsensitiveCompare("api") == .orderedSame else { return nil }
      return Self.nonEmpty(entry.key)
    case .oauthAccess:
      guard entry.type.caseInsensitiveCompare("oauth") == .orderedSame else { return nil }
      if let expires = entry.expires, expires > 0, expires <= Self.currentTimeMilliseconds {
        throw BridgeError.expiredCredential(candidate.authProviderID)
      }
      return Self.nonEmpty(entry.access)
    }
  }

  private static func loadSelectedWSLAuthData(environment: [String: String]) throws -> Data? {
    guard
      let rawDirectory = Self.environmentValue(
        named: Self.wslOpenCodeDataHomeEnvironmentKey,
        in: environment),
      let directory = Self.nonEmpty(rawDirectory)
    else { return nil }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
      .appendingPathComponent("auth.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw BridgeError.invalidAuthFile
    }
  }

  private static var currentTimeMilliseconds: Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
  }

  private static func nonEmpty(_ rawValue: String?) -> String? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else {
      return nil
    }
    if (value.hasPrefix("\"") && value.hasSuffix("\""))
      || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      value = String(value.dropFirst().dropLast())
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func environmentValue(named name: String, in environment: [String: String])
    -> String?
  {
    environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func wslEnvironmentName(_ entry: String) -> String {
    entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? entry
  }
}
