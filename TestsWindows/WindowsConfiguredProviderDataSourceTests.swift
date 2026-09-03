#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows configured provider data source", .serialized)
  struct WindowsConfiguredProviderDataSourceTests {
    @Test("provider source chooses all distributions automatically or one explicit distribution")
    func selectsCandidateDistributions() {
      let automatic = WindowsProviderConfiguration(
        id: .gemini,
        enabled: true,
        order: 0,
        sourceMode: .init(rawValue: "nativeCLI"))
      let explicit = WindowsProviderConfiguration(
        id: .cursor,
        enabled: true,
        order: 1,
        sourceMode: .wsl,
        wslDistro: " Ubuntu ")

      #expect(
        WindowsConfiguredProviderDataSource.candidateDistributions(
          for: automatic,
          installed: ["Debian", "Ubuntu"]) == ["Debian", "Ubuntu"])
      #expect(
        WindowsConfiguredProviderDataSource.candidateDistributions(
          for: explicit,
          installed: ["Debian", "ubuntu"]) == ["ubuntu"])
      #expect(automatic.sourceDisplayName == "Automatic distro · Automatic")
      #expect(explicit.sourceDisplayName == "Ubuntu · Automatic")
    }

    @Test("an explicit missing distribution remains selected for a useful source error")
    func preservesMissingExplicitDistribution() {
      let provider = WindowsProviderConfiguration(
        id: .codex,
        enabled: true,
        order: 0,
        sourceMode: .wsl,
        wslDistro: "Ubuntu-Removed")
      #expect(
        WindowsConfiguredProviderDataSource.candidateDistributions(
          for: provider,
          installed: ["Ubuntu"]) == ["Ubuntu-Removed"])
    }

    @Test("existing CLI in a later distribution wins before bundled provisioning")
    func prefersExistingCLIInEveryCandidate() async {
      let recorder = ResolutionRecorder()
      let resolved = await WindowsConfiguredProviderDataSource.resolveCLI(
        distributions: [" Debian ", "Ubuntu", "debian"],
        existing: { distribution in await recorder.existing(distribution) },
        bundled: { distribution in await recorder.bundled(distribution) })

      #expect(
        resolved
          == WindowsConfiguredProviderDataSource.ResolvedCLI(
            distribution: "Ubuntu",
            executablePath: "/usr/local/bin/codexbar"))
      #expect(await recorder.existingCalls == ["Debian", "Ubuntu"])
      #expect(await recorder.bundledCalls.isEmpty)
    }

    @Test("bundled provisioning starts only after every existing CLI probe misses")
    func provisionsOnlyAfterExistingSearch() async {
      let recorder = ResolutionRecorder(existingPath: nil, bundledDistribution: "Debian")
      let resolved = await WindowsConfiguredProviderDataSource.resolveCLI(
        distributions: ["Debian", "Ubuntu"],
        existing: { distribution in await recorder.existing(distribution) },
        bundled: { distribution in await recorder.bundled(distribution) })

      #expect(resolved?.distribution == "Debian")
      #expect(await recorder.existingCalls == ["Debian", "Ubuntu"])
      #expect(await recorder.bundledCalls == ["Debian"])
    }

    @Test("five provider fetches run together while output order stays stable")
    func boundsParallelProviderFetchesAndPreservesOrder() async {
      let inputs = Array(0..<7)
      let probe = ConcurrencyProbe(expectedInitialCount: 5)
      let operation = Task {
        await WindowsBoundedConcurrentMap.map(
          inputs,
          maximumConcurrentTasks: WindowsConfiguredProviderDataSource
            .maximumConcurrentProviderFetches
        ) { value in
          await probe.run(value)
        }
      }

      await probe.waitForInitialTasks()
      #expect(WindowsConfiguredProviderDataSource.maximumConcurrentProviderFetches == 5)
      #expect(await probe.maximumActiveCount == 5)
      #expect(Set(await probe.startedInputs) == Set(inputs.prefix(5)))
      await probe.releaseAll()

      #expect(await operation.value == inputs.map { "provider-\($0)" })
      #expect(await probe.maximumActiveCount == 5)
      #expect(Set(await probe.startedInputs) == Set(inputs))
    }

    @Test("valid manual early failure is invalidated by replacement during a delayed sibling")
    func validManualFailureRejectsReplacement() async throws {
      let fixture = try DataSourceFixture()
      defer { fixture.remove() }
      try fixture.vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": "manual-before-delay"])
      let snapshot = try #require(await fixture.fetch(bridge: .init()).first)
      #expect(snapshot.availability == .error)
      #expect(snapshot.publicationAuthorityCheck != nil)

      try await Self.expectRejectedAfterDelayedSibling(snapshot) {
        try fixture.vault.save(
          provider: .poe,
          credentialSetID: "api-key",
          submittedValues: ["apiKey": "manual-after-delay"])
      }
    }

    @Test("corrupt manual early failure is invalidated by clear during a delayed sibling")
    func corruptManualFailureRejectsClear() async throws {
      let fixture = try DataSourceFixture()
      defer { fixture.remove() }
      try FileManager.default.createDirectory(
        at: fixture.vault.directoryURL,
        withIntermediateDirectories: true)
      try Data([0, 1, 2, 3]).write(
        to: fixture.vault.directoryURL.appendingPathComponent("poe.bin"))
      let snapshot = try #require(await fixture.fetch(bridge: .init()).first)
      #expect(snapshot.availability == .error)
      #expect(snapshot.publicationAuthorityCheck != nil)

      try await Self.expectRejectedAfterDelayedSibling(snapshot) {
        try fixture.vault.clear(.poe)
      }
    }

    @Test("stable blob identity lookup failure publishes once and replacement invalidates it")
    func identityLookupFailureDoesNotRefreshForever() async throws {
      let fixture = try DataSourceFixture()
      defer { fixture.remove() }
      try FileManager.default.createDirectory(
        at: fixture.vault.directoryURL.appendingPathComponent("poe.bin"),
        withIntermediateDirectories: true)
      let snapshot = try #require(await fixture.fetch(bridge: .init()).first)
      #expect(snapshot.availability == .error)
      #expect(snapshot.sourceText == "Automatic distro · Manual credential")
      #expect(!snapshot.discardsRefreshResult)
      #expect(try snapshot.publicationAuthorityCheck?() == true)

      let initiallyCommitted = DataSourceCommittedProviders()
      let initialOutcome = WindowsProviderSnapshotPublisher.publish([snapshot]) { value in
        initiallyCommitted.append(value.provider)
      }
      #expect(initialOutcome.rejectedProviders.isEmpty)
      #expect(initiallyCommitted.value == [.poe])

      try FileManager.default.removeItem(
        at: fixture.vault.directoryURL.appendingPathComponent("poe.bin"))
      try fixture.vault.save(
        provider: .poe,
        credentialSetID: "api-key",
        submittedValues: ["apiKey": "manual-after-identity-failure"])
      let replacedOutcome = WindowsProviderSnapshotPublisher.publish([snapshot]) { _ in
        Issue.record("Stale lookup failure must not publish after replacement")
      }
      #expect(replacedOutcome.rejectedProviders == [.poe])
    }

    @Test("OpenCode early failure is invalidated by manual save during a delayed sibling")
    func openCodeFailureRejectsManualSave() async throws {
      let fixture = try DataSourceFixture()
      defer { fixture.remove() }
      let bridge = WindowsProviderCredentialBridge(authDataLoader: { _ in Data("{".utf8) })
      let snapshot = try #require(await fixture.fetch(bridge: bridge).first)
      #expect(snapshot.availability == .error)
      #expect(snapshot.sourceText == "Ubuntu · Automatic")
      #expect(snapshot.safeErrorText?.localizedCaseInsensitiveContains("bridge") == false)
      #expect(snapshot.publicationAuthorityCheck != nil)

      try await Self.expectRejectedAfterDelayedSibling(snapshot) {
        try fixture.vault.save(
          provider: .poe,
          credentialSetID: "api-key",
          submittedValues: ["apiKey": "manual-wins-after-delay"])
      }
    }

    @Test("missing CLI result is invalidated when manual intent changes during resolution")
    func unresolvedCLIFailureRejectsManualSave() async throws {
      let fixture = try DataSourceFixture(existingCLI: nil)
      defer { fixture.remove() }
      let snapshot = try #require(await fixture.fetch(bridge: .init()).first)
      #expect(snapshot.availability == .unavailable)
      #expect(snapshot.publicationAuthorityCheck != nil)

      try await Self.expectRejectedAfterDelayedSibling(snapshot) {
        try fixture.vault.save(
          provider: .poe,
          credentialSetID: "api-key",
          submittedValues: ["apiKey": "manual-created-during-resolution"])
      }
    }

    private static func expectRejectedAfterDelayedSibling(
      _ snapshot: WindowsProviderSnapshot,
      mutation: () throws -> Void
    ) async throws {
      let siblingStarted = DispatchSemaphore(value: 0)
      let releaseSibling = DispatchSemaphore(value: 0)
      let batch = Task.detached {
        siblingStarted.signal()
        _ = releaseSibling.wait(timeout: .now() + 5)
        return [
          snapshot,
          WindowsProviderSnapshot(
            provider: .cursor,
            availability: .available,
            sourceText: "Automatic · WSL CLI · Ubuntu"),
        ]
      }
      #expect(siblingStarted.wait(timeout: .now() + 2) == .success)
      try mutation()
      releaseSibling.signal()

      let committed = DataSourceCommittedProviders()
      let outcome = WindowsProviderSnapshotPublisher.publish(await batch.value) { value in
        committed.append(value.provider)
      }
      #expect(outcome.rejectedProviders == [.poe])
      #expect(committed.value == [.cursor])
    }

    private actor ResolutionRecorder {
      private let existingPath: String?
      private let bundledDistribution: String
      private(set) var existingCalls: [String] = []
      private(set) var bundledCalls: [String] = []

      init(
        existingPath: String? = "/usr/local/bin/codexbar",
        bundledDistribution: String = ""
      ) {
        self.existingPath = existingPath
        self.bundledDistribution = bundledDistribution
      }

      func existing(_ distribution: String) -> String? {
        self.existingCalls.append(distribution)
        return distribution == "Ubuntu" ? self.existingPath : nil
      }

      func bundled(_ distribution: String) -> String? {
        self.bundledCalls.append(distribution)
        return distribution == self.bundledDistribution
          ? "/home/example/.local/share/codexbar-windows/0.54.1/CodexBarCLI"
          : nil
      }
    }

    private final class DataSourceFixture: @unchecked Sendable {
      let root: URL
      let store: WindowsConfigurationStore
      let vault: WindowsProviderCredentialVault
      let existingCLI: String?

      init(existingCLI: String? = "/usr/bin/codexbar") throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent(
          "codexbar-data-source-authority-\(Foundation.UUID().uuidString)",
          isDirectory: true)
        self.store = WindowsConfigurationStore(
          fileURL: self.root.appendingPathComponent("config.json"))
        self.vault = WindowsProviderCredentialVault(
          directoryURL: self.root.appendingPathComponent("Credentials"))
        self.existingCLI = existingCLI
        let configuration = WindowsAppConfiguration(providers: [
          WindowsProviderConfiguration(id: .poe, enabled: true, order: 0)
        ])
        try self.store.save(configuration)
      }

      func fetch(bridge: WindowsProviderCredentialBridge) async -> [WindowsProviderSnapshot] {
        let existingCLI = self.existingCLI
        let dataSource = WindowsConfiguredProviderDataSource(
          store: self.store,
          environment: ["WINDIR": "C:\\Windows"],
          wslDistributions: ["Ubuntu"],
          cliDiscoveryCache: WindowsCanonicalCLIDiscoveryCache(
            resolver: { _, _ in existingCLI }),
          bundledCLIDiscoveryCache: WindowsCanonicalCLIDiscoveryCache(
            resolver: { _, _ in nil }),
          credentialBridge: bridge,
          credentialVault: self.vault)
        return await dataSource.fetchProviderSnapshots()
      }

      func remove() {
        try? FileManager.default.removeItem(at: self.root)
      }
    }

    private actor ConcurrencyProbe {
      private let expectedInitialCount: Int
      private var activeCount = 0
      private(set) var maximumActiveCount = 0
      private(set) var startedInputs: [Int] = []
      private var initialTasksContinuation: CheckedContinuation<Void, Never>?
      private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
      private var isReleased = false

      init(expectedInitialCount: Int) {
        self.expectedInitialCount = expectedInitialCount
      }

      func run(_ input: Int) async -> String {
        self.activeCount += 1
        self.maximumActiveCount = max(self.maximumActiveCount, self.activeCount)
        self.startedInputs.append(input)
        if self.startedInputs.count == self.expectedInitialCount {
          self.initialTasksContinuation?.resume()
          self.initialTasksContinuation = nil
        }
        if !self.isReleased {
          await withCheckedContinuation { continuation in
            self.releaseContinuations.append(continuation)
          }
        }
        self.activeCount -= 1
        return "provider-\(input)"
      }

      func waitForInitialTasks() async {
        guard self.startedInputs.count < self.expectedInitialCount else { return }
        await withCheckedContinuation { continuation in
          self.initialTasksContinuation = continuation
        }
      }

      func releaseAll() {
        self.isReleased = true
        let continuations = self.releaseContinuations
        self.releaseContinuations.removeAll()
        for continuation in continuations {
          continuation.resume()
        }
      }
    }
  }

  private final class DataSourceCommittedProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [WindowsProviderID] = []

    var value: [WindowsProviderID] {
      self.lock.withLock { self.providers }
    }

    func append(_ provider: WindowsProviderID) {
      self.lock.withLock { self.providers.append(provider) }
    }
  }
#endif
