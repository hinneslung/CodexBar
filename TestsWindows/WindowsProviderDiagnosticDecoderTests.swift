#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows provider diagnostic decoder")
  struct WindowsProviderDiagnosticDecoderTests {
    @Test("schema 1.0 maps known windows confidence and resolved web source")
    func mapsDiagnosticUsage() throws {
      let snapshot = try WindowsCanonicalCLIProviderClient.decode(
        data: Self.payload(),
        requestedProvider: .init("manus"),
        source: .init(
          distributionLabel: "Ubuntu",
          kind: .manual("Browser session"),
          isResolved: false),
        executionMode: .diagnose)

      #expect(snapshot.availability == .available)
      #expect(snapshot.windows.map(\.label) == ["Session", "Daily"])
      #expect(snapshot.windows.map(\.usedPercent) == [25, 60])
      #expect(snapshot.windows[0].resetsAt == Self.date("2030-01-02T00:00:00Z"))
      #expect(snapshot.windows[1].resetText == "1-day window")
      #expect(snapshot.usageSummaryText == "Estimated usage")
      #expect(snapshot.planText == nil)
      #expect(snapshot.balanceText == nil)
      #expect(snapshot.accountText == nil)
      #expect(snapshot.source.isResolved)
      #expect(snapshot.sourceText == "Ubuntu · Browser session")
      #expect(snapshot.updatedAt == Self.date("2026-08-31T12:37:25Z"))
    }

    @Test("unknown usage windows are omitted")
    func omitsUnknownWindows() throws {
      let snapshot = try WindowsProviderDiagnosticDecoder.decode(
        data: Self.payload(unknownSecondWindow: true),
        requestedProvider: .init("manus"),
        source: .compatibility("Manual · WSL CLI · Ubuntu"))

      #expect(snapshot.windows.map(\.label) == ["Session"])
    }

    @Test("wrong schema provider malformed date and absurd percentages fail closed")
    func rejectsMalformedPayloads() {
      Self.expectFailure(Self.payload(schemaVersion: "2.0"), provider: "manus")
      Self.expectFailure(Self.payload(), provider: "mistral")
      Self.expectFailure(Self.payload(updatedAt: "not-a-date"), provider: "manus")
      Self.expectFailure(Self.payload(usedPercent: "100001"), provider: "manus")
    }

    @Test("over quota and negative percentages clamp for display")
    func clampsRawPercentagesForDisplay() throws {
      let overQuota = try WindowsProviderDiagnosticDecoder.decode(
        data: Self.payload(usedPercent: "120"),
        requestedProvider: .init("manus"),
        source: .compatibility("Manual · WSL CLI · Ubuntu"))
      let negative = try WindowsProviderDiagnosticDecoder.decode(
        data: Self.payload(usedPercent: "-1"),
        requestedProvider: .init("manus"),
        source: .compatibility("Manual · WSL CLI · Ubuntu"))

      #expect(overQuota.windows.first?.usedPercent == 100)
      #expect(negative.windows.first?.usedPercent == 0)
    }

    @Test("oversized arrays strings and provider-specific detail objects fail closed")
    func rejectsOversizedAndUnsupportedShapes() {
      let oversizedModes = (0..<17).map { "mode\($0)" }
      Self.expectFailure(Self.payload(modes: oversizedModes), provider: "manus")
      Self.expectFailure(
        Self.payload(displayName: String(repeating: "x", count: 301)), provider: "manus")
      Self.expectFailure(Self.payload(details: #"{"type":"minimax"}"#), provider: "manus")
    }

    @Test("diagnostic errors map to bounded local messages")
    func mapsSafeError() throws {
      let snapshot = try WindowsProviderDiagnosticDecoder.decode(
        data: Self.payload(
          usage: "null", error: #"{"category":"auth","safeDescription":"raw text"}"#),
        requestedProvider: .init("manus"),
        source: .compatibility("Manual · WSL CLI · Ubuntu"))

      #expect(snapshot.availability == .error)
      #expect(snapshot.safeErrorText == "Provider authentication or setup needs attention.")
      #expect(snapshot.safeErrorText?.contains("raw text") == false)
    }

    @Test("diagnostic failures retain the requested source without exposing failed")
    func retainsRequestedSourceOnFailure() throws {
      let payload = Self.payload(
        usage: "null",
        error: #"{"category":"auth","safeDescription":"raw text"}"#,
        source: "failed")
      let automatic = try WindowsProviderDiagnosticDecoder.decode(
        data: payload,
        requestedProvider: .init("manus"),
        source: .init(
          distributionLabel: "Ubuntu",
          kind: .automatic,
          isResolved: false))
      let manual = try WindowsProviderDiagnosticDecoder.decode(
        data: payload,
        requestedProvider: .init("manus"),
        source: .init(
          distributionLabel: "Ubuntu",
          kind: .manual("Browser session"),
          isResolved: false))

      #expect(automatic.sourceText == "Ubuntu · Automatic")
      #expect(!automatic.source.isResolved)
      #expect(manual.sourceText == "Ubuntu · Browser session")
      #expect(!manual.source.isResolved)
    }

    @Test("only transient diagnostic categories request a retry")
    func classifiesRetryableDiagnosticErrors() throws {
      for category in ["network", "api"] {
        let result = try WindowsProviderDiagnosticDecoder.decodeResult(
          data: Self.payload(
            usage: "null",
            error: #"{"category":"\#(category)","safeDescription":"safe"}"#),
          requestedProvider: .init("manus"),
          source: .compatibility("Manual · WSL CLI · Ubuntu"))
        #expect(result.shouldRetry)
      }
      for category in ["auth", "parse", "configuration", "unknown"] {
        let result = try WindowsProviderDiagnosticDecoder.decodeResult(
          data: Self.payload(
            usage: "null",
            error: #"{"category":"\#(category)","safeDescription":"safe"}"#),
          requestedProvider: .init("manus"),
          source: .compatibility("Manual · WSL CLI · Ubuntu"))
        #expect(!result.shouldRetry)
      }
    }

    @Test("diagnostic payload cannot contain both usage and an error")
    func rejectsAmbiguousOutcome() {
      Self.expectFailure(
        Self.payload(error: #"{"category":"auth","safeDescription":"raw text"}"#),
        provider: "manus")
    }

    @Test("diagnostic source modes and successful source must match staged web route")
    func rejectsSourceMismatch() {
      Self.expectFailure(Self.payload(sourceMode: "api"), provider: "manus")
      Self.expectFailure(Self.payload(settingsSourceMode: "api"), provider: "manus")
      Self.expectFailure(Self.payload(source: "failed"), provider: "manus")
    }

    private static func payload(
      schemaVersion: String = "1.0",
      displayName: String = "Manus",
      updatedAt: String = "2026-08-31T12:37:25Z",
      usedPercent: String = "25",
      unknownSecondWindow: Bool = false,
      modes: [String] = ["web"],
      usage: String? = nil,
      error: String = "null",
      details: String = "null",
      source: String = "web",
      sourceMode: String = "web",
      settingsSourceMode: String? = nil
    ) -> Data {
      let modesJSON = modes.map { #""\#($0)""# }.joined(separator: ",")
      let usageJSON =
        usage ?? #"""
          {
            "updatedAt":"\#(updatedAt)",
            "dataConfidence":"estimated",
            "windows":[
              {
                "label":"primary","usedPercent":\#(usedPercent),"windowMinutes":300,
                "resetsAt":"2030-01-02T00:00:00Z","hasResetDescription":false,
                "nextRegenPercent":null,"usageKnown":true
              },
              {
                "label":"Daily","usedPercent":60,"windowMinutes":1440,
                "resetsAt":null,"hasResetDescription":true,"nextRegenPercent":5,
                "usageKnown":\#(unknownSecondWindow ? "false" : "true")
              }
            ],
            "extraWindowCount":1,
            "providerCostPresent":false,
            "providerSpecificData":[],
            "detailSections":[
              {"title":"Quota","rows":[{"label":"Requests","value":"25 of 100","secondaryValue":null}],"chart":null}
            ]
          }
          """#
      let json = #"""
        {
          "schemaVersion":"\#(schemaVersion)",
          "timestamp":"2026-08-31T12:37:26Z",
          "platform":"Linux",
          "appVersion":"1.2.3",
          "provider":"manus",
          "displayName":"\#(displayName)",
          "source":"\#(source)",
          "sourceMode":"\#(sourceMode)",
          "auth":{"configured":true,"modes":[\#(modesJSON)]},
          "usage":\#(usageJSON),
          "fetchAttempts":[{"kind":"web","wasAvailable":true,"errorCategory":null}],
          "error":\#(error),
          "settings":{"sourceMode":"\#(settingsSourceMode ?? sourceMode)","apiRegion":null},
          "details":\#(details)
        }
        """#
      return Data(json.utf8)
    }

    private static func expectFailure(_ data: Data, provider: String) {
      do {
        _ = try WindowsProviderDiagnosticDecoder.decode(
          data: data,
          requestedProvider: .init(provider),
          source: .compatibility("Manual · WSL CLI · Ubuntu"))
        Issue.record("Expected diagnostic decoding to fail")
      } catch {
        #expect(error is WindowsCanonicalCLIError)
      }
    }

    private static func date(_ value: String) -> Date? {
      ISO8601DateFormatter().date(from: value)
    }
  }
#endif
