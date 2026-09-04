#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows canonical CLI provider client")
  struct WindowsCanonicalCLIProviderClientTests {
    @Test("canonical upstream payload projects arbitrary windows and credits")
    func decodesCanonicalPayload() throws {
      let payload = #"""
        [{
          "provider":"gemini",
          "account":"work",
          "source":"auto",
          "usage":{
            "primary":{"usedPercent":18,"windowMinutes":300,"resetsAt":"2030-01-02T03:04:05Z","resetDescription":null},
            "secondary":{"usedPercent":44,"windowMinutes":10080,"resetsAt":null,"resetDescription":"Sunday"},
            "tertiary":null,
            "extraRateWindows":[{
              "id":"flash",
              "title":"Flash",
              "usageKnown":true,
              "window":{"usedPercent":7,"windowMinutes":1440,"resetsAt":null,"resetDescription":null}
            }],
            "updatedAt":"2026-08-24T01:00:00Z",
            "identity":{"loginMethod":"Google OAuth"}
          },
          "credits":{"remaining":12.5,"events":[],"updatedAt":"2026-08-24T01:00:00Z"},
          "error":null
        }]
        """#

      let snapshot = try WindowsCanonicalCLIProviderClient.decode(
        data: Data(payload.utf8),
        requestedProvider: WindowsProviderID("gemini"),
        sourceText: "WSL CLI · Ubuntu")

      #expect(snapshot.provider.rawValue == "gemini")
      #expect(snapshot.windows.map(\.label) == ["Session", "Weekly", "Flash"])
      #expect(snapshot.windows.map(\.usedPercent) == [18, 44, 7])
      #expect(snapshot.planText == "Plan: Google OAuth")
      #expect(snapshot.balanceText == "12.50 credits remaining")
      #expect(snapshot.accountText == "work")
      #expect(snapshot.sourceText == "WSL CLI · Ubuntu")
    }

    @Test("WSL invocation uses direct arguments without a shell")
    func buildsWSLInvocation() {
      let invocation = WindowsCanonicalCLIInvocation.wsl(
        distribution: "Ubuntu-24.04",
        executablePath: "/opt/codexbar/bin/codexbar",
        providerID: "gemini",
        windowsDirectory: "C:\\Windows")
      #expect(
        invocation.executablePath.replacingOccurrences(of: "\\", with: "/").hasSuffix(
          "Windows/System32/wsl.exe"))
      #expect(
        invocation.arguments == [
          "-d", "Ubuntu-24.04", "--", "/opt/codexbar/bin/codexbar",
          "usage", "--provider", "gemini", "--json-only",
        ])
      #expect(invocation.distribution == "Ubuntu-24.04")
      #expect(invocation.executionMode == .usage)
      #expect(invocation.processTimeout == 45)
    }

    @Test("automatic diagnostic WSL invocation uses exact argv and longer timeout")
    func buildsAutomaticDiagnosticInvocation() {
      let invocation = WindowsCanonicalCLIInvocation.wsl(
        distribution: "Ubuntu",
        executablePath: "/opt/codexbar/CodexBarCLI",
        providerID: "manus",
        executionMode: .diagnose,
        windowsDirectory: "C:\\Windows")

      #expect(
        invocation.arguments == [
          "-d", "Ubuntu", "--", "/opt/codexbar/CodexBarCLI",
          "diagnose", "--provider", "manus", "--format", "json", "--redact",
        ])
      #expect(invocation.standardInput == nil)
      #expect(invocation.executionMode == .diagnose)
      #expect(invocation.processTimeout == 90)
    }

    @Test("staged WSL invocation defaults to usage and supports exact diagnose mode")
    func buildsStagedInvocationModes() {
      let usage = WindowsCanonicalCLIInvocation.stagedWSL(
        distribution: "Ubuntu",
        launcherPath: "/opt/codexbar/CodexBarStagingLauncher",
        providerID: "manus",
        source: "web",
        config: Data("{}".utf8),
        credentialPath: "Browser session",
        windowsDirectory: "C:\\Windows")
      let diagnose = WindowsCanonicalCLIInvocation.stagedWSL(
        distribution: "Ubuntu",
        launcherPath: "/opt/codexbar/CodexBarStagingLauncher",
        providerID: "manus",
        source: "web",
        config: Data("{}".utf8),
        credentialPath: "Browser session",
        executionMode: .diagnose,
        windowsDirectory: "C:\\Windows")

      #expect(usage.executionMode == .usage)
      #expect(usage.arguments.contains("50"))
      #expect(usage.processTimeout == 60)
      #expect(Array(usage.arguments.suffix(4)) == ["--source", "web", "--mode", "usage"])
      #expect(usage.allowsRetry)
      #expect(diagnose.executionMode == .diagnose)
      #expect(diagnose.arguments.contains("75"))
      #expect(diagnose.processTimeout == 90)
      #expect(Array(diagnose.arguments.suffix(4)) == ["--source", "web", "--mode", "diagnose"])
      #expect(diagnose.allowsRetry)
    }

    @Test("canonical WSL discovery accepts only a sanitized absolute codexbar path")
    func validatesDiscoveredExecutable() {
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredExecutablePath(
          Data("/home/linuxbrew/.linuxbrew/bin/codexbar\n".utf8))
          == "/home/linuxbrew/.linuxbrew/bin/codexbar")
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredExecutablePath(
          Data("/home/linuxbrew/.linuxbrew/bin/codex\n".utf8)) == nil)
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredExecutablePath(
          Data("relative/codexbar\n".utf8)) == nil)
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredExecutablePath(
          Data("/usr/bin/codexbar\nsecond-line".utf8)) == "/usr/bin/codexbar")
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredExecutablePath(
          Data("/opt/codexbar/CodexBarCLI\n".utf8)) == nil)
      #expect(
        WindowsCanonicalCLIProviderClient.discoveredLinuxHome(Data("/home/example\n".utf8))
          == "/home/example")
      #expect(WindowsCanonicalCLIProviderClient.discoveredLinuxHome(Data("relative\n".utf8)) == nil)
    }

    @Test("provider usage retries only transient child failures")
    func classifiesRetryableFailures() {
      #expect(WindowsCanonicalCLIProviderClient.shouldRetry(.timedOut))
      #expect(WindowsCanonicalCLIProviderClient.shouldRetry(.commandFailed(1)))
      #expect(!WindowsCanonicalCLIProviderClient.shouldRetry(.invalidPayload))
      #expect(!WindowsCanonicalCLIProviderClient.shouldRetry(.invalidEnvironment))
    }

    @Test("staged provider usage retries one failed attempt after the shared delay")
    func retriesStagedProviderUsage() async {
      let success = WindowsHiddenProcessResult(
        standardOutput: Data(
          #"""
          [{
            "provider":"poe",
            "source":"api",
            "usage":null,
            "credits":{"remaining":12,"updatedAt":"2026-08-24T01:00:00Z"},
            "error":null
          }]
          """#
          .utf8),
        standardError: Data(),
        exitCode: 0)
      let runner = CanonicalRunnerState([
        .failure(.timedOut),
        .success(success),
      ])
      let delays = CanonicalDelayState()
      let client = WindowsCanonicalCLIProviderClient(
        processRunner: { _, _, _, _, _, _ in try runner.next() },
        retryDelay: { delays.record() })
      let invocation = WindowsCanonicalCLIInvocation.stagedWSL(
        distribution: "Ubuntu",
        launcherPath: "/opt/codexbar/CodexBarStagingLauncher",
        providerID: "poe",
        source: "api",
        config: Data("{}".utf8),
        credentialPath: "API key",
        windowsDirectory: "C:\\Windows")

      let snapshot = await client.fetch(provider: .poe, invocation: invocation)

      #expect(snapshot.availability == .available)
      #expect(snapshot.balanceText == "12 credits remaining")
      #expect(runner.attemptCount == 2)
      #expect(delays.count == 1)
    }

    @Test("diagnostic retry remains bounded to one retry within the mode-specific budget")
    func boundsDiagnosticRetry() async {
      let runner = CanonicalRunnerState([
        .failure(.commandFailed(1)),
        .failure(.commandFailed(1)),
      ])
      let delays = CanonicalDelayState()
      let client = WindowsCanonicalCLIProviderClient(
        processRunner: { _, _, timeout, _, _, _ in
          #expect(timeout == 90)
          return try runner.next()
        },
        retryDelay: { delays.record() })
      let invocation = WindowsCanonicalCLIInvocation.wsl(
        distribution: "Ubuntu",
        executablePath: "/opt/codexbar/bundled/CodexBarCLI",
        providerID: "manus",
        executionMode: .diagnose,
        windowsDirectory: "C:\\Windows")

      let snapshot = await client.fetch(provider: .manus, invocation: invocation)

      #expect(snapshot.availability == .unavailable)
      #expect(runner.attemptCount == 2)
      #expect(delays.count == 1)
    }

    @Test("stale credentials discard the complete refresh instead of publishing cached usage")
    func discardsStaleCredentialFetch() async {
      let invocation = WindowsCanonicalCLIInvocation(
        executablePath: "C:\\does-not-run.exe",
        arguments: [],
        sourceText: "Manual · WSL CLI · Fixture",
        distribution: "Fixture",
        standardInput: nil,
        allowsRetry: false)
      let snapshot = await WindowsCanonicalCLIProviderClient().fetch(
        provider: .poe,
        invocation: invocation,
        authorityCheck: { false })

      #expect(snapshot.discardsRefreshResult)
      #expect(snapshot.availability == .unavailable)
      #expect(snapshot.usedPercent == nil)
    }

    @Test("ordinary fetch failures retain their final publication authority check")
    func failedFetchRetainsPublicationAuthority() async throws {
      let authority = CanonicalAuthorityState(true)
      let invocation = WindowsCanonicalCLIInvocation(
        executablePath: "C:\\does-not-run.exe",
        arguments: [],
        sourceText: "Manual · WSL CLI · Fixture",
        distribution: "Fixture",
        standardInput: nil,
        allowsRetry: false)
      let snapshot = await WindowsCanonicalCLIProviderClient().fetch(
        provider: .poe,
        invocation: invocation,
        authorityCheck: { authority.value })

      #expect(!snapshot.discardsRefreshResult)
      #expect(snapshot.availability == .unavailable)
      let publicationAuthorityCheck = try #require(snapshot.publicationAuthorityCheck)
      authority.set(false)
      #expect(try !publicationAuthorityCheck())
    }

    @Test("balance identity is promoted instead of being shown as a plan")
    func promotesBalanceIdentity() throws {
      let payload =
        #"""
        {
          "provider":"poe",
          "source":"api",
          "usage":{
            "primary":null,
            "secondary":null,
            "tertiary":null,
            "extraRateWindows":[],
            "updatedAt":"2026-08-24T01:00:00Z",
            "identity":{"loginMethod":"Balance: 4321 points"}
          },
          "credits":null,
          "error":null
        }
        """#
      let snapshot = try WindowsCanonicalCLIProviderClient.decode(
        data: Data(payload.utf8),
        requestedProvider: .poe,
        sourceText: "WSL CLI · Ubuntu")

      #expect(snapshot.planText == nil)
      #expect(snapshot.balanceText == "4321 points remaining")
    }

    @Test("plain point identity is promoted as an allocation-free balance")
    func promotesPlainPointIdentity() throws {
      let payload =
        #"""
        {
          "provider":"poe",
          "source":"api",
          "usage":{
            "primary":null,
            "secondary":null,
            "tertiary":null,
            "extraRateWindows":[],
            "updatedAt":"2026-08-24T01:00:00Z",
            "identity":{"loginMethod":"991,856 points"}
          },
          "credits":null,
          "error":null
        }
        """#
      let snapshot = try WindowsCanonicalCLIProviderClient.decode(
        data: Data(payload.utf8),
        requestedProvider: .poe,
        sourceText: "WSL CLI · Ubuntu")

      #expect(snapshot.planText == nil)
      #expect(snapshot.balanceText == "991,856 points remaining")
    }
  }

  private final class CanonicalAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
      self.storedValue = value
    }

    var value: Bool {
      self.lock.withLock { self.storedValue }
    }

    func set(_ value: Bool) {
      self.lock.withLock { self.storedValue = value }
    }
  }

  private final class CanonicalRunnerState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<WindowsHiddenProcessResult, WindowsCanonicalCLIError>]
    private var storedAttemptCount = 0

    init(_ results: [Result<WindowsHiddenProcessResult, WindowsCanonicalCLIError>]) {
      self.results = results
    }

    var attemptCount: Int {
      self.lock.withLock { self.storedAttemptCount }
    }

    func next() throws -> WindowsHiddenProcessResult {
      try self.lock.withLock {
        self.storedAttemptCount += 1
        return try self.results.removeFirst().get()
      }
    }
  }

  private final class CanonicalDelayState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
      self.lock.withLock { self.storedCount }
    }

    func record() {
      self.lock.withLock { self.storedCount += 1 }
    }
  }
#endif
