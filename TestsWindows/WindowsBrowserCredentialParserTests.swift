#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows browser credential parser")
  struct WindowsBrowserCredentialParserTests {
    private static let browserProviderIDs: Set<String> = [
      "alibabatokenplan", "amp", "commandcode", "cursor", "grok", "ollama",
      "opencodego", "qoder", "qwencloud", "sakana", "longcat", "manus", "mimo",
      "mistral", "opencode", "perplexity", "t3chat", "zoommate", "notion",
    ]

    private static let diagnosticProviderIDs: Set<String> = [
      "longcat", "manus", "mimo", "mistral", "opencode", "perplexity", "stepfun",
      "t3chat", "zoommate", "notion",
    ]

    @Test
    func `catalog exposes exactly the approved browser routes`() throws {
      let entries = WindowsProviderConfigurationCatalog.schemas.compactMap { schema in
        schema.credentialSet(id: "browser-session").map { (schema, $0) }
      }
      #expect(Set(entries.map(\.0.provider.rawValue)) == Self.browserProviderIDs)
      #expect(entries.count == Self.browserProviderIDs.count)
      #expect(
        WindowsProviderConfigurationCatalog.byProvider[.copilot]?.credentialSet(
          id: "browser-session") == nil)
      #expect(WindowsProviderConfigurationCatalog.byProvider[.devin] == nil)
      let unsupported: [WindowsProviderID] = [
        .abacus, .augment, .claude, .codex, .devin, .factory, .kimi, .minimax,
        .windsurf, .zed,
      ]
      for provider in unsupported {
        #expect(
          WindowsProviderConfigurationCatalog.byProvider[provider]?
            .credentialSet(id: "browser-session") == nil)
      }

      for (schema, set) in entries {
        #expect(set.source == "web")
        #expect(set.acceptsManual)
        #expect(!set.acceptsOpenCode)
        #expect(set.derivesManualCookieSource)
        #expect(set.role == .alternateRoute)
        #expect(!set.captureInstructions.isEmpty)
        #expect(set.securityNotice == nil)
        let policy = try #require(set.inputPolicy)
        #expect(!policy.acceptedHosts.isEmpty)
        #expect(set.fields.first?.storage == .cookieHeader)
        #expect(
          set.fields.first?.guidance
            == "Treat this value like a password. It can expire when you sign out.")
        #expect(schema.cliName.isEmpty == false)
        #expect(
          set.executionMode
            == (Self.diagnosticProviderIDs.contains(schema.provider.rawValue) ? .diagnose : .usage))
      }
    }

    @Test
    func `new API and diagnostic methods share one executable credential-set catalog`() throws {
      let newAPIProviders: Set<WindowsProviderID> = [
        .neuralwatt, .elevenLabs, .warp, .clawRouter, .llmProxy, .liteLLM, .sub2API, .xAI,
      ]
      for provider in newAPIProviders {
        let set = try #require(
          WindowsProviderConfigurationCatalog.byProvider[provider]?.credentialSet(id: "api-key"))
        #expect(set.acceptsManual)
        #expect(set.executionMode == .usage)
        #expect(set.source == "api")
        #expect(set.fields.first?.storage == .apiKey)
      }

      for providerID in Self.diagnosticProviderIDs {
        let provider = WindowsProviderID(providerID)
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[provider])
        #expect(schema.manualCredentialSets.count == 1)
        let set = try #require(schema.manualCredentialSets.first)
        #expect(set.executionMode == .diagnose)
        #expect(set.source == "web")
      }

      let stepFun = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.stepFun]?.credentialSet(
          id: "session-token"))
      #expect(stepFun.label == "Session token")
      #expect(stepFun.fields.map(\.storage) == [.region])
      let record = WindowsProviderCredentialRecord(
        provider: .stepFun,
        credentialSetID: stepFun.id,
        values: ["region": "fixture-oasis-token"])
      let staged = try WindowsStagedProviderConfig.encodeManual(provider: .stepFun, record: record)
      let object = try #require(JSONSerialization.jsonObject(with: staged.data) as? [String: Any])
      let providers = try #require(object["providers"] as? [[String: Any]])
      #expect(providers.count == 1)
      let payload = try #require(providers.first)
      #expect(payload["source"] as? String == "web")
      #expect(payload["cookieSource"] as? String == "manual")
      #expect(payload["region"] as? String == "fixture-oasis-token")
    }

    @Test
    func `cookie inputs normalize structurally and preserve OpenCode Go compatibility`() throws {
      let field = try Self.browserField(.openCodeGo)
      let fixtures: [(String, String, String)] = [
        ("theme=dark; auth=fixture", "theme=dark; auth=fixture", "Detected: Cookie header"),
        ("Cookie: theme=dark; auth=fixture", "theme=dark; auth=fixture", "Detected: Cookie header"),
        (
          "curl 'https://opencode.ai/workspace' -H 'Accept: application/json' "
            + "-H 'Cookie: theme=dark; auth=fixture'",
          "theme=dark; auth=fixture",
          "Detected: cURL request for opencode.ai"
        ),
        (
          "curl --url=https://app.opencode.ai/workspace --header='Cookie: __Host-auth=fixture'",
          "__Host-auth=fixture",
          "Detected: cURL request for app.opencode.ai"
        ),
        (
          "curl https://opencode.ai/workspace --cookie 'auth=fixture' --compressed",
          "auth=fixture",
          "Detected: cURL request for opencode.ai"
        ),
        (
          """
          curl 'https://opencode.ai/workspace' \\
            -H 'accept: application/json' \\
            -H 'cookie: oc_locale=en; auth=fixture-browser-session' \\
            --compressed
          """,
          "oc_locale=en; auth=fixture-browser-session",
          "Detected: cURL request for opencode.ai"
        ),
      ]
      for (input, expected, summary) in fixtures {
        let result = try #require(field.displaySafeValidationResult(input))
        #expect(result.normalizedValue == expected)
        #expect(result.summary == summary)
        #expect(!result.summary.contains("fixture"))
      }
    }

    @Test
    func `cookie parser rejects malformed and wrong-host captures`() throws {
      let field = try Self.browserField(.openCodeGo)
      let rejected = [
        "", "theme=dark", "auth=one; auth=two",
        "curl https://example.com -H 'Cookie: auth=fixture'",
        "curl http://opencode.ai -H 'Cookie: auth=fixture'",
        "curl https://opencode.ai -H 'Accept: application/json'",
        "curl 'https://opencode.ai -H 'Cookie: auth=fixture'",
        "curl https://opencode.ai -b @cookies.txt",
        "curl \"https://opencode.ai/workspace\" ^ -H \"Cookie: auth=fixture\"",
        "auth=fixture\0hidden",
        String(repeating: "a", count: WindowsBrowserCredentialParser.maximumInputBytes + 1),
      ]
      for input in rejected {
        #expect(field.displaySafeValidationResult(input)?.isValid == false)
      }
      let missing = try #require(
        field.displaySafeValidationResult(
          "curl https://opencode.ai -H 'Accept: application/json'"))
      #expect(missing.summary == "Missing Cookie header")
      #expect(!missing.summary.contains("fixture"))
    }

    @Test
    func `browser instructions name the actual Chrome copy commands`() throws {
      let standardProviders: [WindowsProviderID] = [
        .alibabaTokenPlan, .amp, .commandCode, .cursor, .grok, .openCodeGo, .qwenCloud,
        .sakana,
      ]
      for provider in standardProviders {
        let set = try #require(
          WindowsProviderConfigurationCatalog.byProvider[provider]?
            .credentialSet(id: "browser-session"))
        #expect(set.captureInstructions.count == 6)
        #expect(set.captureInstructions[1] == "Press F12, open Network, then reload the page.")
        #expect(set.captureInstructions[3].contains("Headers > Request Headers"))
        #expect(set.captureInstructions[5].contains("Copy as cURL (bash)"))
        #expect(set.fields.first?.label == "Cookie or cURL (bash)")
        #expect(
          set.fields.first?.guidance
            == "Treat this value like a password. It can expire when you sign out."
        )
        #expect(set.securityNotice == nil)
      }

      let qoder = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.qoder]?
          .credentialSet(id: "browser-session"))
      #expect(qoder.captureInstructions[3].contains("Copy as cURL (bash)"))
      #expect(qoder.fields.first?.label == "Cookie or full cURL (bash)")

      let ollama = try #require(
        WindowsProviderConfigurationCatalog.byProvider[.ollama]?
          .credentialSet(id: "browser-session"))
      #expect(ollama.captureInstructions.last?.contains("without its name") == true)
      #expect(ollama.fields.first?.label == "Cookie, cURL (bash), or session")
    }

    @Test
    func `provider ordering subtitles distinguish distro and credential type`() {
      let disabled = WindowsProviderConfiguration(id: .openCodeGo, enabled: false, order: 0)
      #expect(
        WindowsProviderSettingsPresentation.subtitle(configuration: disabled, sourceText: nil)
          == "OpenCode · API key · Browser session")

      let providerSignIn = WindowsProviderConfiguration(id: .codex, enabled: false, order: 0)
      #expect(
        WindowsProviderSettingsPresentation.subtitle(configuration: providerSignIn, sourceText: nil)
          == "Provider app/CLI")

      for provider in WindowsProviderConfigurationCatalog.unavailableProviderIDs {
        let configuration = WindowsProviderConfiguration(id: provider, enabled: false, order: 0)
        #expect(
          WindowsProviderSettingsPresentation.subtitle(
            configuration: configuration,
            sourceText: nil) == "Unavailable on Windows")
      }

      let explicit = WindowsProviderConfiguration(
        id: .openCodeGo,
        enabled: true,
        order: 0,
        sourceMode: .wsl,
        wslDistro: "Ubuntu")
      #expect(
        WindowsProviderSettingsPresentation.subtitle(
          configuration: explicit,
          sourceText: "Ubuntu · Browser session")
          == "Ubuntu · Browser session")

      var automatic = explicit
      automatic.sourceMode = .automatic
      automatic.wslDistro = nil
      #expect(
        WindowsProviderSettingsPresentation.subtitle(
          configuration: automatic,
          sourceText: "Ubuntu · OpenCode")
          == "Ubuntu · OpenCode")

      #expect(
        WindowsProviderSettingsPresentation.subtitle(configuration: automatic, sourceText: nil)
          == "Automatic distro · Automatic")
    }

    @Test
    func `full captures retain only upstream-consumed data deterministically`() throws {
      let policy = WindowsBrowserCredentialPolicy(
        input: .fullRequest(allowCookieHeader: true),
        acceptedHosts: ["capture.example.test"],
        requiredCookieNames: ["session"],
        forwardedHeaders: [
          "user-agent": "User-Agent",
          "x-client-version": "X-Client-Version",
        ])
      let capture = """
        curl 'https://capture.example.test/usage' \
          --header 'X-Unrelated-Canary: must-not-survive' \
          --header 'User-Agent: fixture-agent' \
          --header 'X-Client-Version: 23.13.0' \
          --header 'Cookie: session=fixture-session; locale=en'
        """
      let first = WindowsBrowserCredentialParser.validate(capture, policy: policy)
      let second = WindowsBrowserCredentialParser.validate(capture, policy: policy)
      let canonical = try #require(first.normalizedValue)
      #expect(canonical == second.normalizedValue)
      #expect(canonical.contains("X-Client-Version: 23.13.0"))
      #expect(canonical.contains("User-Agent: fixture-agent"))
      #expect(canonical.contains("-H 'Cookie: session=fixture-session; locale=en'"))
      #expect(!canonical.contains("--header"))
      #expect(!canonical.contains("X-Unrelated-Canary"))
      #expect(first.summary == "Detected: cURL request for capture.example.test")
      #expect(!first.summary.contains("fixture"))
    }

    @Test
    func `query handling is explicit per full-capture route`() throws {
      let qoder = try Self.browserField(.qoder)
      let qoderCapture =
        "curl 'https://qoder.com/api/v2/me/usages/big_model_credits?fixture=1' "
        + "-H 'Cookie: session=fixture'"
      #expect(
        qoder.displaySafeValidationResult(qoderCapture)?.normalizedValue?.contains("?fixture=1")
          == true)

      let exactPolicy = WindowsBrowserCredentialPolicy(
        input: .fullRequest(allowCookieHeader: false),
        acceptedHosts: ["capture.example.test"],
        forwardedHeaders: ["authorization": "Authorization"],
        requiredHeaders: ["authorization"],
        exactPath: "/credits/status",
        allowsQuery: false,
        cookieRequired: false)
      let valid =
        "curl 'https://capture.example.test/credits/status' "
        + "-H 'authorization: Bearer fixture-token'"
      #expect(WindowsBrowserCredentialParser.validate(valid, policy: exactPolicy).isValid)
      let withQuery =
        "curl 'https://capture.example.test/credits/status?account=fixture' "
        + "-H 'authorization: Bearer fixture-token'"
      let queryResult = WindowsBrowserCredentialParser.validate(withQuery, policy: exactPolicy)
      #expect(!queryResult.isValid)
      #expect(queryResult.summary == "Captured request query is not supported")
    }

    @Test
    func `full capture rejects executable or lossy cURL shapes`() throws {
      let field = try Self.browserField(.qoder)
      let rejected = [
        "curl https://qoder.com -H 'Cookie: session=fixture' ; echo owned",
        "curl https://qoder.com -H 'Cookie: session=fixture' && whoami",
        "curl https://qoder.com/$(whoami) -H 'Cookie: session=fixture'",
        "curl https://qoder.com/`whoami` -H 'Cookie: session=fixture'",
        "curl https://qoder.com -H 'Cookie: session=fixture' --data @body.json",
        "curl -X POST https://qoder.com -H 'Cookie: session=fixture'",
        "curl --proxy https://proxy.test https://qoder.com -H 'Cookie: session=fixture'",
        "curl --output result.txt https://qoder.com -H 'Cookie: session=fixture'",
        "curl https://qoder.com https://qoder.com.cn -H 'Cookie: session=fixture'",
        "curl https://user:password@qoder.com -H 'Cookie: session=fixture'",
      ]
      for input in rejected {
        #expect(field.displaySafeValidationResult(input)?.isValid == false)
      }
    }

    @Test
    func `opaque Ollama sessions canonicalize without accepting malformed values`() throws {
      let field = try Self.browserField(.ollama)
      #expect(field.normalized("fixture-session") == "__Secure-session=fixture-session")
      #expect(field.normalized("Cookie: session=fixture") == "session=fixture")
      #expect(
        field.normalized("Cookie: __Secure-next-auth.session-token.0=fixture")
          == "__Secure-next-auth.session-token.0=fixture")
      #expect(field.normalized("unknown=value") == nil)
      #expect(field.normalized("two words") == nil)
    }

    @Test
    func `diagnostic browser policies enforce upstream cookie and header requirements`() throws {
      let mistral = try Self.browserField(.mistral)
      #expect(mistral.normalized("ory_session_fixture=abc; csrftoken=csrf") != nil)
      #expect(mistral.normalized("ory_session_fixture=abc") == nil)
      #expect(mistral.normalized("csrftoken=csrf") == nil)

      let mimo = try Self.browserField(.mimo)
      #expect(mimo.normalized("userId=user; api-platform_serviceToken=token") != nil)
      #expect(mimo.normalized("userId=user") == nil)

      let zoomMate = try Self.browserField(.zoomMate)
      #expect(
        zoomMate.normalized(
          "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' "
            + "-H 'Authorization: Bearer fixture-token'") != nil)
      #expect(zoomMate.normalized("Authorization: Bearer fixture-token") == nil)
      #expect(
        zoomMate.normalized(
          "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status?workspace=fixture' "
            + "-H 'Authorization: Bearer fixture-token'") == nil)
    }

    @Test
    func `every browser route stages only a manual web cookie mapping`() throws {
      for providerID in Self.browserProviderIDs.sorted() {
        let provider = WindowsProviderID(rawValue: providerID)
        let schema = try #require(WindowsProviderConfigurationCatalog.byProvider[provider])
        let set = try #require(schema.credentialSet(id: "browser-session"))
        let field = try #require(set.fields.first)
        let policy = try #require(set.inputPolicy)
        let submitted = Self.validFixture(policy: policy)
        let normalized = try #require(field.normalized(submitted))
        var values = ["cookieHeader": normalized]
        if provider == .alibabaTokenPlan { values["region"] = "intl-personal" }
        let record = WindowsProviderCredentialRecord(
          provider: provider,
          credentialSetID: set.id,
          values: values)
        let staged = try WindowsStagedProviderConfig.encodeManual(
          provider: provider, record: record)
        #expect(staged.source == "web")
        let json = try #require(JSONSerialization.jsonObject(with: staged.data) as? [String: Any])
        let providers = try #require(json["providers"] as? [[String: Any]])
        let payload = try #require(providers.first)
        #expect(payload["id"] as? String == provider.rawValue)
        #expect(payload["source"] as? String == "web")
        #expect(payload["cookieSource"] as? String == "manual")
        #expect(payload["cookieHeader"] as? String == normalized)
        #expect(payload["apiKey"] == nil)
        #expect(payload["secretKey"] == nil)
      }
    }

    private static func browserField(
      _ provider: WindowsProviderID
    ) throws -> WindowsProviderConfigurationField {
      let set = try #require(
        WindowsProviderConfigurationCatalog.byProvider[provider]?
          .credentialSet(id: "browser-session"))
      return try #require(set.fields.first)
    }

    private static func validFixture(policy: WindowsBrowserCredentialPolicy) -> String {
      let cookies: String =
        if policy.requiredCookieNames.isEmpty && policy.requiredCookieNamePrefixes.isEmpty {
          "session=fixture"
        } else if policy.requiresAllCookieNames {
          (policy.requiredCookieNames.map { "\($0)=fixture" }
            + policy.requiredCookieNamePrefixes.map { "\($0)fixture=fixture" }).joined(
              separator: "; ")
        } else if let exact = policy.requiredCookieNames.first {
          "\(exact)=fixture"
        } else {
          "\(policy.requiredCookieNamePrefixes[0])fixture=fixture"
        }
      switch policy.input {
      case .cookieHeader, .cookieHeaderOrCURL:
        return cookies
      case .opaqueSession:
        return "fixture-session"
      case .fullRequest(let allowCookieHeader):
        if allowCookieHeader { return cookies }
        let host = policy.acceptedHosts[0]
        let path = policy.exactPath ?? "/"
        return "curl 'https://\(host)\(path)' -H 'Authorization: Bearer fixture'"
      }
    }
  }
#endif
