import Foundation

struct WindowsProviderSourcePresentation: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case automatic
    case openCode
    case manual(String)
    case upstream(String)
    case compatibility(String)
  }

  let distributionLabel: String?
  let kind: Kind
  let isResolved: Bool

  init(distributionLabel: String?, kind: Kind, isResolved: Bool) {
    self.distributionLabel = Self.normalized(distributionLabel)
    self.kind = kind
    self.isResolved = isResolved
  }

  var formattedValue: String {
    if case .compatibility(let value) = self.kind {
      return Self.upstreamLabel(value)
    }
    return "\(Self.normalized(self.distributionLabel) ?? "Automatic distro") · \(self.sourceLabel)"
  }

  var isExplicitCredentialRoute: Bool {
    switch self.kind {
    case .manual, .openCode:
      true
    case .automatic, .upstream, .compatibility:
      false
    }
  }

  var isManualCredentialRoute: Bool {
    if case .manual = self.kind { return true }
    return false
  }

  func resolvingUpstream(_ value: String?, provider: WindowsProviderID? = nil) -> Self {
    switch self.kind {
    case .automatic:
      return Self(
        distributionLabel: self.distributionLabel,
        kind: .upstream(Self.upstreamLabel(value, provider: provider)),
        isResolved: true)
    case .openCode, .manual:
      return Self(distributionLabel: self.distributionLabel, kind: self.kind, isResolved: true)
    case .upstream, .compatibility:
      return self
    }
  }

  static func configuredFallback(
    configuration: WindowsProviderConfiguration,
    credentialLabel: String? = nil
  ) -> Self {
    let distribution =
      configuration.sourceMode == .wsl ? configuration.wslDistro : nil
    let kind = credentialLabel.map(Kind.manual) ?? .automatic
    return Self(distributionLabel: distribution, kind: kind, isResolved: false)
  }

  static func compatibility(_ value: String) -> Self {
    Self(distributionLabel: nil, kind: .compatibility(value), isResolved: false)
  }

  private var sourceLabel: String {
    switch self.kind {
    case .automatic:
      "Automatic"
    case .openCode:
      "OpenCode"
    case .manual(let label), .upstream(let label):
      Self.upstreamLabel(label)
    case .compatibility(let label):
      Self.upstreamLabel(label)
    }
  }

  private static func upstreamLabel(
    _ value: String?,
    provider: WindowsProviderID? = nil
  ) -> String {
    guard let normalized = Self.normalized(value) else { return "Automatic" }
    let lowercase = normalized.lowercased()
    switch lowercase {
    case "", "auto", "automatic":
      return "Automatic"
    case "api", "api key":
      return "API key"
    case "oauth":
      return "OAuth"
    case "web", "browser session":
      return "Browser session"
    case "cli", "provider cli":
      return "Provider CLI"
    case "opencode", "opencode bridge":
      return "OpenCode"
    default:
      break
    }

    if let provider,
      Self.canonicalIdentifier(normalized) == Self.canonicalIdentifier(provider.rawValue)
        || Self.canonicalIdentifier(normalized) == Self.canonicalIdentifier(provider.cliName)
        || Self.canonicalIdentifier(normalized) == Self.canonicalIdentifier(provider.displayName)
    {
      return "\(provider.displayName) CLI"
    }
    if lowercase.hasSuffix("-cli") {
      return "\(Self.humanizedLabel(String(normalized.dropLast(4)))) CLI"
    }
    if lowercase.hasSuffix("-api") {
      return "\(Self.humanizedLabel(String(normalized.dropLast(4)))) API"
    }
    if lowercase.hasSuffix("-web") {
      return "Browser session"
    }

    return Self.humanizedLabel(
      normalized.replacingOccurrences(
        of: "OpenCode bridge",
        with: "OpenCode",
        options: .caseInsensitive))
  }

  private static func canonicalIdentifier(_ value: String) -> String {
    value.unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map { String($0).lowercased() }
      .joined()
  }

  private static func humanizedLabel(_ value: String) -> String {
    value
      .components(separatedBy: CharacterSet(charactersIn: "-_"))
      .filter { !$0.isEmpty }
      .map { component in
        switch component.lowercased() {
        case "api": "API"
        case "cli": "CLI"
        case "oauth": "OAuth"
        case "openai": "OpenAI"
        case "opencode": "OpenCode"
        default:
          component == component.lowercased()
            ? component.prefix(1).uppercased() + component.dropFirst()
            : component
        }
      }
      .joined(separator: " ")
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    guard
      value.unicodeScalars.allSatisfy({ scalar in
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate:
          return false
        default:
          return true
        }
      })
    else { return nil }
    let normalized =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    return String(normalized.unicodeScalars.prefix(150))
  }
}

enum WindowsProviderCapabilityPresentation {
  static func summary(provider: WindowsProviderID) -> String {
    if WindowsProviderConfigurationCatalog.unavailableProviderIDs.contains(provider) {
      return "Unavailable on Windows"
    }
    return self.labels(
      providerSignIn: WindowsProviderConfigurationCatalog.providerSignInProviderIDs.contains(
        provider),
      supportsOpenCode: WindowsProviderCredentialBridge.supports(provider),
      manualLabels: WindowsProviderConfigurationCatalog.byProvider[provider]?
        .manualCredentialSets.map(\.label) ?? []
    ).joined(separator: " · ")
  }

  static func labels(
    providerSignIn: Bool,
    supportsOpenCode: Bool,
    manualLabels: [String]
  ) -> [String] {
    var labels: [String] = []
    if providerSignIn { labels.append("Provider app/CLI") }
    if supportsOpenCode { labels.append("OpenCode") }
    labels.append(contentsOf: manualLabels)

    var seen = Set<String>()
    return labels.filter { label in
      seen.insert(label.lowercased()).inserted
    }
  }
}
