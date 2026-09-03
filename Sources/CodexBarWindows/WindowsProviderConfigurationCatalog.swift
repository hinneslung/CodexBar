import Foundation

struct WindowsProviderConfigurationField: Sendable, Equatable {
  enum Storage: String, Codable, Sendable, Equatable {
    case apiKey
    case secretKey
    case cookieHeader
    case region
    case workspaceID
    case enterpriseHost
  }

  enum Style: Sendable, Equatable {
    case secureSingleLine
    case secureMultiline
    case plainText
  }

  enum Validation: Sendable, Equatable {
    case secret
    case browserCredential(WindowsBrowserCredentialPolicy)
    case nonempty
    case azureEndpoint
    case privateNetworkHTTPURL
    case sub2APIURL
    case xAITeamID
    case openCodeWorkspaceID
    case oneOf([String])
  }

  let id: String
  let storage: Storage
  let label: String
  let placeholder: String
  let guidance: String?
  let style: Style
  let required: Bool
  let validation: Validation

  var secret: Bool {
    self.style == .secureSingleLine || self.style == .secureMultiline
  }

  var multiline: Bool {
    self.style == .secureMultiline
  }

  var isBrowserCredential: Bool {
    if case .browserCredential = self.validation { return true }
    return false
  }

  func accepts(_ value: String) -> Bool {
    WindowsProviderConfigurationValidator.accepts(value, validation: self.validation)
  }

  func normalized(_ value: String) -> String? {
    switch self.validation {
    case .browserCredential(let policy):
      return WindowsBrowserCredentialParser.validate(value, policy: policy).normalizedValue
    default:
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return self.accepts(trimmed) ? trimmed : nil
    }
  }

  func displaySafeValidationResult(_ value: String) -> WindowsBrowserCredentialValidationResult? {
    guard case .browserCredential(let policy) = self.validation else { return nil }
    return WindowsBrowserCredentialParser.validate(value, policy: policy)
  }
}

struct WindowsProviderCredentialSet: Sendable, Equatable {
  enum Role: Sendable, Equatable {
    case primaryAuthentication
    case alternateRoute
    case optionalEnrichment
  }

  let id: String
  let label: String
  let source: String
  let acceptsManual: Bool
  let acceptsOpenCode: Bool
  let derivesManualCookieSource: Bool
  let fields: [WindowsProviderConfigurationField]
  let role: Role
  let captureInstructions: [String]
  let securityNotice: String?
  let executionMode: WindowsCanonicalCLIInvocation.ExecutionMode

  init(
    id: String,
    label: String,
    source: String,
    acceptsManual: Bool,
    acceptsOpenCode: Bool,
    derivesManualCookieSource: Bool,
    fields: [WindowsProviderConfigurationField],
    role: Role = .primaryAuthentication,
    captureInstructions: [String] = [],
    securityNotice: String? = nil,
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode = .usage
  ) {
    self.id = id
    self.label = label
    self.source = source
    self.acceptsManual = acceptsManual
    self.acceptsOpenCode = acceptsOpenCode
    self.derivesManualCookieSource = derivesManualCookieSource
    self.fields = fields
    self.role = role
    self.captureInstructions = captureInstructions
    self.securityNotice = securityNotice
    self.executionMode = executionMode
  }

  var inputPolicy: WindowsBrowserCredentialPolicy? {
    for field in self.fields {
      if case .browserCredential(let policy) = field.validation { return policy }
    }
    return nil
  }
}

struct WindowsProviderConfigurationSchema: Sendable, Equatable {
  let provider: WindowsProviderID
  let cliName: String
  let credentialSets: [WindowsProviderCredentialSet]

  var manualCredentialSets: [WindowsProviderCredentialSet] {
    self.credentialSets.filter(\.acceptsManual)
  }

  var manualCredentialTypeSummary: String {
    let labels = self.manualCredentialSets.map(\.label)
    return labels.isEmpty ? "No manual credential setup" : labels.joined(separator: " · ")
  }

  /// Compatibility view for noncredential Windows state. Manual editors select a concrete set.
  var fields: [WindowsProviderConfigurationField] {
    self.credentialSets.first?.fields ?? []
  }

  func credentialSet(id: String?) -> WindowsProviderCredentialSet? {
    guard let id else { return nil }
    return self.manualCredentialSets.first { $0.id == id }
  }
}

struct WindowsUnavailableProviderInfo: Sendable, Equatable {
  let explanation: String
  let resourceURL: String?
}

/// Declarative Windows-owned manual credential catalog. It mirrors only configuration fields and
/// source routes already consumed by the unchanged bundled Linux CLI.
enum WindowsProviderConfigurationCatalog {
  enum ProviderAppOrCLIEvidence: Sendable, Equatable {
    case providerCLI
    case providerOwnedAuthenticationState
    case providerOwnedLocalSource
  }

  /// Providers whose upstream descriptor has a reviewed non-manual route through the provider's
  /// CLI, app-owned authentication state, or local service. Automatic selection alone is not evidence.
  static let providerAppOrCLIEvidence: [WindowsProviderID: ProviderAppOrCLIEvidence] = [
    .amp: .providerCLI,
    .antigravity: .providerCLI,
    .augment: .providerCLI,
    .bedrock: .providerOwnedAuthenticationState,
    .claude: .providerCLI,
    .codebuff: .providerOwnedAuthenticationState,
    .codex: .providerCLI,
    .doubao: .providerCLI,
    .factory: .providerOwnedLocalSource,
    .gemini: .providerOwnedAuthenticationState,
    .grok: .providerCLI,
    .jetBrains: .providerOwnedAuthenticationState,
    .kilo: .providerCLI,
    .kimi: .providerOwnedAuthenticationState,
    .kiro: .providerCLI,
    .vertexAI: .providerOwnedAuthenticationState,
    .wayfinder: .providerOwnedLocalSource,
  ]

  static var providerAppOrCLIProviderIDs: Set<WindowsProviderID> {
    Set(self.providerAppOrCLIEvidence.keys)
  }

  static func automaticCredentialDescription(provider: WindowsProviderID) -> String {
    let providerAppOrCLI = self.providerAppOrCLIProviderIDs.contains(provider)
    let supportsOpenCode = WindowsProviderCredentialBridge.supports(provider)
    var sentences: [String] =
      switch (providerAppOrCLI, supportsOpenCode) {
      case (true, true):
        [
          "Automatically uses its OpenCode CLI connection.",
          "Otherwise, uses credentials from the provider's app or CLI.",
        ]
      case (true, false):
        ["Automatically uses credentials from the provider's app or CLI."]
      case (false, true):
        [
          "Automatically uses its OpenCode CLI connection.",
          "Otherwise, uses CodexBar CLI credentials.",
        ]
      case (false, false):
        ["Automatically uses CodexBar CLI credentials."]
      }

    let hasManualCredential = self.byProvider[provider]?.manualCredentialSets.isEmpty == false
    if hasManualCredential {
      sentences.append("Select a manual option if Automatic fails.")
    }
    return sentences.joined(separator: " ")
  }

  /// API routes whose staged `apiKey` was proven to be consumed by the unchanged release CLI.
  static let manualAPIProviderIDs: Set<WindowsProviderID> = [
    .aiAnd, .alibaba, .amp, .azureOpenAI, .chutes, .claude, .codebuff, .copilot,
    .crof, .deepgram, .deepInfra, .doubao, .elevenLabs, .factory, .fireworks, .groq, .ibmBob,
    .kilo, .kimi, .liteLLM, .llmProxy, .moonshot, .neuralwatt, .ollama, .openai,
    .openCodeGo, .openRouter, .poe, .sub2API, .synthetic, .venice, .warp, .xAI,
    .zai, .zenMux, .clawRouter,
  ]

  static let unavailableProviders: [WindowsProviderID: WindowsUnavailableProviderInfo] = [
    .abacus: .init(
      explanation: "The upstream Abacus integration is currently available only on macOS.",
      resourceURL: "https://github.com/steipete/CodexBar/blob/main/docs/abacus.md"),
    .devin: .init(
      explanation: "The unchanged Linux CLI has no safe configuration route for Devin credentials.",
      resourceURL: "https://github.com/steipete/CodexBar/blob/main/docs/devin.md"),
    .windsurf: .init(
      explanation: "The upstream Windsurf integration depends on macOS browser and local app data.",
      resourceURL: "https://github.com/steipete/CodexBar/blob/main/docs/windsurf.md"),
    .zed: .init(
      explanation: "The upstream Zed integration reads its sign-in from macOS Keychain.",
      resourceURL: "https://github.com/steipete/CodexBar/blob/main/docs/zed.md"),
  ]

  static var unavailableProviderIDs: Set<WindowsProviderID> {
    Set(self.unavailableProviders.keys)
  }

  static func unavailableInfo(for provider: WindowsProviderID) -> WindowsUnavailableProviderInfo? {
    self.unavailableProviders[provider]
  }

  static func supportsConfigurationControls(for provider: WindowsProviderID) -> Bool {
    self.unavailableInfo(for: provider) == nil
  }

  private static let apiKey = WindowsProviderConfigurationField(
    id: "apiKey",
    storage: .apiKey,
    label: "API key",
    placeholder: "Paste API key",
    guidance: nil,
    style: .secureSingleLine,
    required: true,
    validation: .secret)

  private static let openCodeWorkspace = WindowsProviderConfigurationField(
    id: "workspaceID",
    storage: .workspaceID,
    label: "Workspace (optional)",
    placeholder: "wrk_…",
    guidance: "Leave blank unless automatic workspace discovery fails.",
    style: .plainText,
    required: false,
    validation: .openCodeWorkspaceID)

  private static let alibabaTokenRegion = WindowsProviderConfigurationField(
    id: "region",
    storage: .region,
    label: "Region and plan type",
    placeholder: "intl, cn, intl-personal, or cn-personal",
    guidance: "Choose the region and Team or Personal plan matching the captured console session.",
    style: .plainText,
    required: true,
    validation: .oneOf(["intl", "cn", "intl-personal", "cn-personal"]))

  private static let browserSecurityNotice =
    "Treat this value like a password. It can expire when you sign out."

  private static let alibabaHosts = [
    "modelstudio.console.alibabacloud.com",
    "bailian.console.aliyun.com",
    "bailian-singapore-cs.alibabacloud.com",
    "bailian-cs.console.aliyun.com",
  ]

  private static let qwenCloudHosts = [
    "qwencloud.com", "home.qwencloud.com", "account.qwencloud.com",
    "signin.qwencloud.com", "www.qwencloud.com", "alibabacloud.com",
    "account.alibabacloud.com", "aliyun.com", "console.aliyun.com",
  ]

  private static let ollamaCookieNames = [
    "session", "__Secure-session", "ollama_session", "__Host-ollama_session",
    "wos-session", "__Secure-next-auth.session-token", "next-auth.session-token",
  ]

  private static let cursorCookieNames = [
    "WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token",
    "wos-session", "__Secure-wos-session", "authjs.session-token",
    "__Secure-authjs.session-token",
  ]

  private static let commandCodeCookieNames = [
    "__Secure-commandcode_prod_.session_token", "commandcode_prod_.session_token",
    "__Host-commandcode_prod_.session_token", "__Host-better-auth.session_token",
    "__Secure-better-auth.session_token", "better-auth.session_token",
  ]

  private static var qoderBrowserSet: WindowsProviderCredentialSet {
    browserSet(
      site: "qoder.com or qoder.com.cn",
      hosts: ["qoder.com", "www.qoder.com", "qoder.com.cn", "www.qoder.com.cn"],
      input: .fullRequest(allowCookieHeader: true))
  }

  private static let stepFunSessionToken = WindowsProviderConfigurationField(
    id: "region",
    storage: .region,
    label: "Session token",
    placeholder: "Paste Oasis-Token value",
    guidance: Self.browserSecurityNotice,
    style: .secureSingleLine,
    required: true,
    validation: .secret)

  static let schemas: [WindowsProviderConfigurationSchema] = [
    Self.apiSchema(.aiAnd, "aiand"),
    Self.apiSchema(.alibaba, "alibaba-coding-plan"),
    Self.apiSchema(
      .alibabaTokenPlan, "alibaba-token-plan",
      additionalSets: [
        Self.browserSet(
          site: "Model Studio or Bailian",
          hosts: Self.alibabaHosts,
          companions: [Self.alibabaTokenRegion])
      ]),
    Self.apiSchema(
      .amp, "amp",
      additionalSets: [
        Self.browserSet(
          site: "ampcode.com",
          hosts: ["ampcode.com", "www.ampcode.com"],
          requiredCookieNames: ["session"])
      ]),
    Self.apiSchema(
      .azureOpenAI, "azure-openai",
      companions: [
        .init(
          id: "enterpriseHost",
          storage: .enterpriseHost,
          label: "Endpoint",
          placeholder: "https://resource.openai.azure.com",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .azureEndpoint),
        .init(
          id: "workspaceID",
          storage: .workspaceID,
          label: "Deployment",
          placeholder: "deployment-name",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .nonempty),
      ]),
    Self.apiSchema(.chutes, "chutes"),
    Self.apiSchema(.claude, "claude"),
    Self.apiSchema(.clawRouter, "clawrouter"),
    Self.apiSchema(.clinePass, "clinepass"),
    Self.apiSchema(.codebuff, "codebuff"),
    Self.apiSchema(.copilot, "copilot"),
    Self.apiSchema(
      .commandCode, "commandcode",
      additionalSets: [
        Self.browserSet(
          site: "commandcode.ai",
          hosts: ["commandcode.ai", "www.commandcode.ai", "api.commandcode.ai"],
          requiredCookieNames: Self.commandCodeCookieNames)
      ]),
    Self.apiSchema(.crof, "crof"),
    Self.apiSchema(
      .cursor, "cursor",
      additionalSets: [
        Self.browserSet(
          site: "cursor.com",
          hosts: ["cursor.com", "www.cursor.com", "cursor.sh", "authenticator.cursor.sh"],
          requiredCookieNames: Self.cursorCookieNames)
      ]),
    Self.apiSchema(.deepgram, "deepgram"),
    Self.apiSchema(.deepInfra, "deepinfra"),
    Self.apiSchema(.deepSeek, "deepseek"),
    Self.apiSchema(.doubao, "doubao"),
    Self.apiSchema(.elevenLabs, "elevenlabs"),
    Self.apiSchema(.factory, "factory"),
    Self.apiSchema(.fireworks, "fireworks"),
    Self.apiSchema(.groq, "groqcloud"),
    Self.apiSchema(
      .grok, "grok",
      additionalSets: [
        Self.browserSet(site: "grok.com", hosts: ["grok.com"])
      ]),
    Self.apiSchema(.ibmBob, "ibmbob"),
    Self.apiSchema(.kilo, "kilo"),
    Self.apiSchema(.kimi, "kimi"),
    Self.webSchema(
      .longCat,
      "longcat",
      set: Self.browserSet(
        site: "longcat.chat",
        hosts: ["longcat.chat", "www.longcat.chat"],
        executionMode: .diagnose)),
    Self.apiSchema(
      .liteLLM, "litellm",
      companions: [
        .init(
          id: "enterpriseHost",
          storage: .enterpriseHost,
          label: "Base URL",
          placeholder: "https://litellm.example.test",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .privateNetworkHTTPURL)
      ]),
    Self.apiSchema(
      .llmProxy, "llmproxy",
      companions: [
        .init(
          id: "enterpriseHost",
          storage: .enterpriseHost,
          label: "Base URL",
          placeholder: "https://proxy.example.test",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .privateNetworkHTTPURL)
      ]),
    Self.apiSchema(.minimax, "minimax"),
    Self.webSchema(
      .manus,
      "manus",
      set: Self.browserSet(
        site: "manus.im",
        hosts: ["manus.im", "www.manus.im", "api.manus.im"],
        requiredCookieNames: ["session_id"],
        executionMode: .diagnose)),
    Self.webSchema(
      .mimo,
      "mimo",
      set: Self.browserSet(
        site: "platform.xiaomimimo.com",
        hosts: ["platform.xiaomimimo.com", "xiaomimimo.com", "www.xiaomimimo.com"],
        requiredCookieNames: ["api-platform_serviceToken", "userId"],
        requiresAllCookieNames: true,
        executionMode: .diagnose)),
    Self.webSchema(
      .mistral,
      "mistral",
      set: Self.browserSet(
        site: "admin.mistral.ai",
        hosts: ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "console.mistral.ai"],
        requiredCookieNames: ["csrftoken"],
        requiredCookieNamePrefixes: ["ory_session_"],
        requiresAllCookieNames: true,
        executionMode: .diagnose)),
    Self.apiSchema(.moonshot, "moonshot"),
    Self.apiSchema(.neuralwatt, "neuralwatt"),
    Self.apiSchema(
      .ollama, "ollama",
      additionalSets: [
        Self.browserSet(
          site: "ollama.com",
          hosts: ["ollama.com", "www.ollama.com", "signin.ollama.com", "auth.workos.com"],
          input: .opaqueSession(
            defaultCookieName: "__Secure-session",
            recognizedCookieNames: Self.ollamaCookieNames),
          requiredCookieNames: Self.ollamaCookieNames)
      ]),
    Self.apiSchema(.openai, "openai"),
    Self.webSchema(
      .openCode,
      "opencode",
      set: Self.browserSet(
        site: "opencode.ai",
        hosts: ["opencode.ai", "app.opencode.ai"],
        requiredCookieNames: ["auth", "__Host-auth"],
        companions: [Self.openCodeWorkspace],
        executionMode: .diagnose)),
    Self.apiSchema(
      .openCodeGo,
      "opencodego",
      additionalSets: [
        .init(
          id: "browser-session",
          label: "Browser session",
          source: "web",
          acceptsManual: true,
          acceptsOpenCode: false,
          derivesManualCookieSource: true,
          fields: [
            Self.browserField(
              site: "opencode.ai",
              hosts: ["opencode.ai", "app.opencode.ai"],
              requiredCookieNames: ["auth", "__Host-auth"]),
            Self.openCodeWorkspace,
          ],
          role: .alternateRoute,
          captureInstructions: Self.captureInstructions(
            site: "opencode.ai", input: .cookieHeaderOrCURL, cookieRequired: true))
      ]),
    Self.apiSchema(.openRouter, "openrouter"),
    Self.webSchema(
      .perplexity,
      "perplexity",
      set: Self.browserSet(
        site: "perplexity.ai",
        hosts: ["perplexity.ai", "www.perplexity.ai"],
        requiredCookieNames: [
          "__Secure-authjs.session-token", "authjs.session-token",
          "__Secure-next-auth.session-token", "next-auth.session-token",
        ],
        executionMode: .diagnose)),
    Self.apiSchema(.poe, "poe"),
    Self.apiSchema(
      .qoder, "qoder",
      additionalSets: [Self.qoderBrowserSet]),
    Self.apiSchema(
      .qwenCloud, "qwen-cloud",
      additionalSets: [
        Self.browserSet(
          site: "home.qwencloud.com",
          hosts: Self.qwenCloudHosts,
          requiredCookieNames: [
            "login_aliyunid_ticket", "login_qwencloud_ticket", "qwen_sso_ticket",
          ])
      ]),
    Self.webSchema(
      .stepFun,
      "stepfun",
      set: .init(
        id: "session-token",
        label: "Session token",
        source: "web",
        acceptsManual: true,
        acceptsOpenCode: false,
        derivesManualCookieSource: true,
        fields: [Self.stepFunSessionToken],
        role: .alternateRoute,
        executionMode: .diagnose)),
    Self.apiSchema(
      .sakana, "sakana",
      additionalSets: [
        Self.browserSet(site: "console.sakana.ai", hosts: ["console.sakana.ai"])
      ]),
    Self.apiSchema(
      .sub2API, "sub2api",
      companions: [
        .init(
          id: "enterpriseHost",
          storage: .enterpriseHost,
          label: "Base URL",
          placeholder: "https://sub2api.example.test",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .sub2APIURL)
      ]),
    Self.apiSchema(.synthetic, "synthetic"),
    Self.webSchema(
      .t3Chat,
      "t3chat",
      set: Self.browserSet(
        site: "t3.chat",
        hosts: ["t3.chat", "www.t3.chat"],
        executionMode: .diagnose)),
    Self.apiSchema(.venice, "venice"),
    Self.apiSchema(.warp, "warp"),
    Self.webSchema(
      .zoomMate,
      "zoommate",
      set: Self.browserSet(
        site: "ai.zoom.us",
        hosts: ["ai.zoom.us", "zoommate.zoom.us"],
        input: .fullRequest(allowCookieHeader: false),
        forwardedHeaders: ["authorization": "Authorization"],
        requiredHeaders: ["authorization"],
        exactPath: "/ai-computer/api/v1/credits/status",
        allowsQuery: false,
        cookieRequired: false,
        executionMode: .diagnose)),
    Self.apiSchema(
      .xAI, "xai",
      companions: [
        .init(
          id: "workspaceID",
          storage: .workspaceID,
          label: "Team ID",
          placeholder: "team-id",
          guidance: nil,
          style: .plainText,
          required: true,
          validation: .xAITeamID)
      ]),
    Self.webSchema(
      .notion,
      "notion",
      set: Self.browserSet(
        site: "app.notion.com",
        hosts: ["app.notion.com", "notion.so", "www.notion.so"],
        requiredCookieNames: ["token_v2"],
        executionMode: .diagnose)),
    Self.apiSchema(.zai, "zai"),
    Self.apiSchema(.zenMux, "zenmux"),
  ]

  static let byProvider: [WindowsProviderID: WindowsProviderConfigurationSchema] =
    Dictionary(uniqueKeysWithValues: Self.schemas.map { ($0.provider, $0) })

  static func credentialSet(provider: WindowsProviderID, id: String?)
    -> WindowsProviderCredentialSet?
  {
    self.byProvider[provider]?.credentialSet(id: id)
  }

  private static func browserSet(
    site: String,
    hosts: [String],
    input: WindowsBrowserCredentialPolicy.Input = .cookieHeaderOrCURL,
    requiredCookieNames: [String] = [],
    requiredCookieNamePrefixes: [String] = [],
    requiresAllCookieNames: Bool = false,
    forwardedHeaders: [String: String] = [:],
    requiredHeaders: [String] = [],
    exactPath: String? = nil,
    allowsQuery: Bool = true,
    cookieRequired: Bool = true,
    companions: [WindowsProviderConfigurationField] = [],
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode = .usage
  ) -> WindowsProviderCredentialSet {
    let field = Self.browserField(
      site: site,
      hosts: hosts,
      input: input,
      requiredCookieNames: requiredCookieNames,
      requiredCookieNamePrefixes: requiredCookieNamePrefixes,
      requiresAllCookieNames: requiresAllCookieNames,
      forwardedHeaders: forwardedHeaders,
      requiredHeaders: requiredHeaders,
      exactPath: exactPath,
      allowsQuery: allowsQuery,
      cookieRequired: cookieRequired)
    return WindowsProviderCredentialSet(
      id: "browser-session",
      label: "Browser session",
      source: "web",
      acceptsManual: true,
      acceptsOpenCode: false,
      derivesManualCookieSource: true,
      fields: [field] + companions,
      role: .alternateRoute,
      captureInstructions: Self.captureInstructions(
        site: site, input: input, cookieRequired: cookieRequired),
      executionMode: executionMode)
  }

  private static func browserField(
    site: String,
    hosts: [String],
    input: WindowsBrowserCredentialPolicy.Input = .cookieHeaderOrCURL,
    requiredCookieNames: [String] = [],
    requiredCookieNamePrefixes: [String] = [],
    requiresAllCookieNames: Bool = false,
    forwardedHeaders: [String: String] = [:],
    requiredHeaders: [String] = [],
    exactPath: String? = nil,
    allowsQuery: Bool = true,
    cookieRequired: Bool = true
  ) -> WindowsProviderConfigurationField {
    let policy = WindowsBrowserCredentialPolicy(
      input: input,
      acceptedHosts: hosts,
      requiredCookieNames: requiredCookieNames,
      requiredCookieNamePrefixes: requiredCookieNamePrefixes,
      requiresAllCookieNames: requiresAllCookieNames,
      forwardedHeaders: forwardedHeaders,
      requiredHeaders: requiredHeaders,
      exactPath: exactPath,
      allowsQuery: allowsQuery,
      cookieRequired: cookieRequired)
    let label: String
    let placeholder: String
    switch input {
    case .cookieHeader:
      label = "Cookie header"
      placeholder = "Cookie request-header value"
    case .cookieHeaderOrCURL:
      label = "Cookie or cURL (bash)"
      placeholder = "Cookie value or Copy as cURL (bash)"
    case .fullRequest(let allowCookieHeader):
      label = allowCookieHeader ? "Cookie or full cURL (bash)" : "Full cURL (bash)"
      placeholder =
        allowCookieHeader
        ? "Cookie value or Copy as cURL (bash)"
        : "Copy as cURL (bash)"
    case .opaqueSession:
      label = "Cookie, cURL (bash), or session"
      placeholder = "Cookie value, cURL (bash), or session value"
    }
    return WindowsProviderConfigurationField(
      id: "cookieHeader",
      storage: .cookieHeader,
      label: label,
      placeholder: placeholder,
      guidance: Self.browserSecurityNotice,
      style: .secureMultiline,
      required: true,
      validation: .browserCredential(policy))
  }

  private static func captureInstructions(
    site: String,
    input: WindowsBrowserCredentialPolicy.Input,
    cookieRequired: Bool
  ) -> [String] {
    let common = [
      "Sign in to \(site) in Chrome.",
      "Press F12, open Network, then reload the page.",
      cookieRequired
        ? "Select a request to that site that has Cookie under Request Headers."
        : "Select the credits status request to that site.",
    ]
    switch input {
    case .cookieHeader, .cookieHeaderOrCURL:
      return common + [
        "In Headers > Request Headers, right-click Cookie > Copy value.",
        "Paste that value below. It must include the cookie name, such as auth=….",
        "Or right-click the request > Copy > Copy as cURL (bash), then paste the whole command.",
      ]
    case .fullRequest(let allowCookieHeader):
      var instructions =
        common + [
          "Right-click the request > Copy > Copy as cURL (bash).",
          "Paste the whole command below so CodexBar can retain the correct service address.",
        ]
      if allowCookieHeader {
        instructions.append(
          "A Cookie > Copy value paste is also accepted for the default international service.")
      }
      return instructions
    case .opaqueSession:
      return common + [
        "In Headers > Request Headers, right-click Cookie > Copy value.",
        "Paste it below, or use request > Copy > Copy as cURL (bash).",
        "A copied session-cookie value without its name is also accepted.",
      ]
    }
  }

  private static func apiSchema(
    _ provider: WindowsProviderID,
    _ cliName: String,
    companions: [WindowsProviderConfigurationField] = [],
    additionalSets: [WindowsProviderCredentialSet] = []
  ) -> WindowsProviderConfigurationSchema {
    WindowsProviderConfigurationSchema(
      provider: provider,
      cliName: cliName,
      credentialSets: [
        .init(
          id: "api-key",
          label: "API key",
          source: "api",
          acceptsManual: self.manualAPIProviderIDs.contains(provider),
          acceptsOpenCode: true,
          derivesManualCookieSource: false,
          fields: [self.apiKey] + companions)
      ] + additionalSets)
  }

  private static func webSchema(
    _ provider: WindowsProviderID,
    _ cliName: String,
    set: WindowsProviderCredentialSet
  ) -> WindowsProviderConfigurationSchema {
    WindowsProviderConfigurationSchema(
      provider: provider,
      cliName: cliName,
      credentialSets: [set])
  }
}

enum WindowsProviderSettingsPresentation {
  static func subtitle(
    configuration: WindowsProviderConfiguration,
    sourceText: String?
  ) -> String {
    guard configuration.enabled else {
      return WindowsProviderCapabilityPresentation.summary(provider: configuration.id)
    }
    if let sourceText {
      let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty,
        normalized.caseInsensitiveCompare("Source unavailable") != .orderedSame,
        normalized.caseInsensitiveCompare("Unavailable") != .orderedSame
      {
        return normalized.replacingOccurrences(
          of: "OpenCode bridge",
          with: "OpenCode",
          options: .caseInsensitive)
      }
    }
    return WindowsProviderSourcePresentation.configuredFallback(configuration: configuration)
      .formattedValue
  }
}

enum WindowsProviderConfigurationValidator {
  static func accepts(
    _ rawValue: String,
    validation: WindowsProviderConfigurationField.Validation
  ) -> Bool {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 65536, !value.contains("\0")
    else { return false }

    switch validation {
    case .secret, .nonempty:
      return !value.contains(where: \.isNewline)
    case .browserCredential(let policy):
      return WindowsBrowserCredentialParser.validate(rawValue, policy: policy).isValid
    case .azureEndpoint:
      return Self.normalizedHTTPSURL(value) != nil
    case .privateNetworkHTTPURL:
      return Self.validatedURL(value, allowingHTTPFor: Self.isPrivateNetworkHost) != nil
    case .sub2APIURL:
      guard let url = Self.validatedURL(value, allowingHTTPFor: Self.isLoopbackHost) else {
        return false
      }
      return url.query == nil && url.fragment == nil
    case .xAITeamID:
      return !value.contains("/") && value != "." && value != ".."
    case .openCodeWorkspaceID:
      return value.hasPrefix("wrk_") && !value.contains(where: \.isNewline)
    case .oneOf(let values):
      return values.contains(value)
    }
  }

  private static func normalizedHTTPSURL(_ raw: String) -> URL? {
    let url = Self.hasExplicitURLScheme(raw) ? URL(string: raw) : URL(string: "https://\(raw)")
    guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      Self.validatedHost(url) != nil
    else { return nil }
    return url
  }

  private static func validatedURL(
    _ raw: String,
    allowingHTTPFor permitsHTTP: (String) -> Bool
  ) -> URL? {
    guard self.hasExplicitURLScheme(raw), let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.user == nil, url.password == nil, let host = validatedHost(url),
      scheme == "https" || permitsHTTP(host)
    else { return nil }
    return url
  }

  private static func validatedHost(_ url: URL) -> String? {
    guard let decoded = url.host(percentEncoded: false)?.lowercased(), !decoded.isEmpty,
      !decoded.contains("%"),
      decoded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      decoded.rangeOfCharacter(from: .controlCharacters) == nil,
      let encoded = url.host(percentEncoded: true)?.lowercased()
    else { return nil }
    if decoded.contains(":") {
      guard encoded == decoded,
        let component = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
        component.hasPrefix("["), component.hasSuffix("]")
      else { return nil }
      let address = component.dropFirst().dropLast()
      guard !address.isEmpty, address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
      else { return nil }
      return decoded
    }
    let decodedDelimiters = CharacterSet(charactersIn: "/\\?#@:")
    guard decoded.rangeOfCharacter(from: decodedDelimiters) == nil else { return nil }
    let encodedDelimiters = ["%2f", "%5c", "%3f", "%23", "%40", "%3a"]
    return encodedDelimiters.contains(where: encoded.contains) ? nil : decoded
  }

  private static func hasExplicitURLScheme(_ raw: String) -> Bool {
    guard let colon = raw.firstIndex(of: ":") else { return false }
    if raw[colon...].hasPrefix("://") { return true }
    if let end = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }), colon > end {
      return false
    }
    let afterColon = raw.index(after: colon)
    guard afterColon < raw.endIndex else { return true }
    let portEnd =
      raw[afterColon...].firstIndex(where: { ["/", "?", "#"].contains($0) }) ?? raw.endIndex
    let suffix = raw[afterColon..<portEnd]
    if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
    let scheme = raw[..<colon]
    guard let first = scheme.first, first.isLetter else { return false }
    return scheme.dropFirst().allSatisfy {
      $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0)
    }
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" { return true }
    guard let octets = ipv4Octets(host) else { return false }
    return octets[0] == 127
  }

  private static func isPrivateNetworkHost(_ host: String) -> Bool {
    if self.isLoopbackHost(host) { return true }
    let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
    if hostname.hasSuffix(".local"), hostname.count > ".local".count { return true }
    if let octets = Self.ipv4Octets(host) {
      return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
        || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
    guard Self.isValidIPv6Address(host),
      let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
      !first.isEmpty, let firstValue = UInt16(first, radix: 16)
    else { return false }
    return firstValue & 0xFE00 == 0xFC00 || firstValue & 0xFFC0 == 0xFE80
  }

  private static func ipv4Octets(_ host: String) -> [UInt8]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var result: [UInt8] = []
    for part in parts {
      guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
        part == "0" || part.first != "0", let octet = UInt8(part)
      else { return nil }
      result.append(octet)
    }
    return result
  }

  private static func isValidIPv6Address(_ host: String) -> Bool {
    guard host.contains(":") else { return false }
    var address = host
    if address.contains(".") {
      guard let colon = address.lastIndex(of: ":"),
        Self.ipv4Octets(String(address[address.index(after: colon)...])) != nil
      else { return false }
      address.replaceSubrange(address.index(after: colon)..., with: "0:0")
    }
    let compressed = address.components(separatedBy: "::")
    guard compressed.count <= 2 else { return false }
    let counts = compressed.map(Self.ipv6GroupCount)
    guard counts.allSatisfy({ $0 != nil }) else { return false }
    let count = counts.compactMap(\.self).reduce(0, +)
    return compressed.count == 2 ? count < 8 : count == 8
  }

  private static func ipv6GroupCount(_ part: String) -> Int? {
    if part.isEmpty { return 0 }
    let groups = part.split(separator: ":", omittingEmptySubsequences: false)
    guard
      groups.allSatisfy({ group in
        (1...4).contains(group.utf8.count) && group.allSatisfy(\.isHexDigit)
      })
    else { return nil }
    return groups.count
  }
}
