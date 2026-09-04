import Foundation

struct WindowsProviderCredentialRouteAuthority: Sendable {
  let manualSelected: Bool
  let manualLabel: String?
  let captureError: WindowsProviderCredentialVaultError?
  let check: (@Sendable () throws -> Bool)?
}

struct WindowsProviderCredentialRouteResolver: Sendable {
  private let credentialVault: WindowsProviderCredentialVault?

  init(credentialVault: WindowsProviderCredentialVault?) {
    self.credentialVault = credentialVault
  }

  func load(_ provider: WindowsProviderID) throws -> WindowsProviderCredentialRecord? {
    try self.credentialVault?.load(provider)
  }

  func resolve(_ provider: WindowsProviderID) -> WindowsProviderCredentialRouteAuthority {
    guard let credentialVault = self.credentialVault,
      WindowsProviderConfigurationCatalog.byProvider[provider] != nil
    else {
      return WindowsProviderCredentialRouteAuthority(
        manualSelected: false,
        manualLabel: nil,
        captureError: nil,
        check: nil)
    }
    do {
      let identity = try credentialVault.protectedBlobIdentity(provider)
      let record = identity == nil ? nil : try credentialVault.load(provider)
      let manualLabel = record.flatMap {
        WindowsProviderConfigurationCatalog.credentialSet(
          provider: provider,
          id: $0.credentialSetID)?.label
      }
      return WindowsProviderCredentialRouteAuthority(
        manualSelected: identity != nil,
        manualLabel: manualLabel ?? (identity == nil ? nil : "Manual credential"),
        captureError: nil,
        check: {
          try credentialVault.protectedBlobIdentity(provider) == identity
        })
    } catch {
      let captureError =
        error as? WindowsProviderCredentialVaultError
        ?? WindowsProviderCredentialVaultError.storageFailed
      return WindowsProviderCredentialRouteAuthority(
        manualSelected: true,
        manualLabel: "Manual credential",
        captureError: captureError,
        check: {
          do {
            _ = try credentialVault.protectedBlobIdentity(provider)
            return false
          } catch {
            return (error as? WindowsProviderCredentialVaultError) == captureError
          }
        })
    }
  }
}

/// Resolves every provider through the same canonical CodexBar CLI contract.
/// Windows-specific code discovers credentials; upstream remains the only provider usage engine.
struct WindowsConfiguredProviderDataSource: WindowsProviderDataSource, Sendable {
  static let maximumConcurrentProviderFetches = 5
  private let store: WindowsConfigurationStore?
  private let environment: [String: String]
  private let wslDistributions: [String]
  private let cliClient: WindowsCanonicalCLIProviderClient
  private let cliDiscoveryCache: WindowsCanonicalCLIDiscoveryCache
  private let bundledCLIDiscoveryCache: WindowsCanonicalCLIDiscoveryCache
  private let credentialBridge: WindowsProviderCredentialBridge
  private let credentialRouteResolver: WindowsProviderCredentialRouteResolver

  init(
    store: WindowsConfigurationStore?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    wslDistributions: [String]? = nil,
    cliDiscoveryCache: WindowsCanonicalCLIDiscoveryCache = WindowsCanonicalCLIDiscoveryCache(),
    bundledCLIDiscoveryCache: WindowsCanonicalCLIDiscoveryCache = WindowsCanonicalCLIDiscoveryCache(
      resolver: { distribution, windowsDirectory in
        await Task.detached(priority: .utility) {
          WindowsBundledWSLCLIProvisioner().provision(
            distribution: distribution,
            windowsDirectory: windowsDirectory)
        }.value
      }),
    cliClient: WindowsCanonicalCLIProviderClient = WindowsCanonicalCLIProviderClient(),
    credentialBridge: WindowsProviderCredentialBridge = WindowsProviderCredentialBridge(),
    credentialVault: WindowsProviderCredentialVault? = try? WindowsProviderCredentialVault(),
    credentialRouteResolver: WindowsProviderCredentialRouteResolver? = nil
  ) {
    self.store = store
    self.environment = environment
    self.wslDistributions = wslDistributions ?? WindowsWSLDistributionRegistry.names()
    self.cliDiscoveryCache = cliDiscoveryCache
    self.bundledCLIDiscoveryCache = bundledCLIDiscoveryCache
    self.cliClient = cliClient
    self.credentialBridge = credentialBridge
    self.credentialRouteResolver =
      credentialRouteResolver
      ?? WindowsProviderCredentialRouteResolver(credentialVault: credentialVault)
  }

  func fetchProviderSnapshots() async -> [WindowsProviderSnapshot] {
    let configuration = (try? self.store?.load()) ?? .defaults
    let enabled = configuration.providers
      .filter(\.enabled)
      .sorted(by: Self.providerOrder)
    guard !enabled.isEmpty else { return [] }

    return await WindowsBoundedConcurrentMap.map(
      enabled,
      maximumConcurrentTasks: Self.maximumConcurrentProviderFetches
    ) { provider in
      await self.fetch(provider)
    }
  }

  // swiftlint:disable:next function_body_length
  private func fetch(_ provider: WindowsProviderConfiguration) async -> WindowsProviderSnapshot {
    let credentialRoute = self.credentialRouteResolver.resolve(provider.id)
    let configuredSource = WindowsProviderSourcePresentation.configuredFallback(
      configuration: provider,
      credentialLabel: credentialRoute.manualLabel)
    if let captureError = credentialRoute.captureError {
      return Self.credentialFailure(
        provider: provider.id,
        path: "Manual",
        source: configuredSource,
        error: captureError,
        authorityCheck: credentialRoute.check)
    }
    let distributions = Self.candidateDistributions(
      for: provider,
      installed: self.wslDistributions)
    let windowsDirectory = self.environment["WINDIR"] ?? "C:\\Windows"
    let resolved = await self.resolvedCLI(
      distributions: distributions,
      windowsDirectory: windowsDirectory)
    guard let resolved else {
      return Self.unavailable(
        provider,
        source: configuredSource,
        authorityCheck: credentialRoute.check)
    }

    if credentialRoute.manualSelected {
      var authorityCheck = credentialRoute.check
      do {
        guard let record = try self.credentialRouteResolver.load(provider.id) else {
          throw WindowsProviderCredentialVaultError.corruptedCredential
        }
        authorityCheck = {
          try self.credentialRouteResolver.load(provider.id)?.revision == record.revision
        }
        let staged = try WindowsStagedProviderConfig.encodeManual(
          provider: provider.id,
          record: record)
        guard
          let credentialSet = WindowsProviderConfigurationCatalog.credentialSet(
            provider: provider.id,
            id: record.credentialSetID)
        else { throw WindowsStagedProviderConfigError.invalidCredentialSet }
        let credentialLabel = credentialSet.label
        guard
          let invocation = await self.stagedInvocation(
            resolvedUsageCLI: resolved,
            provider: provider.id,
            source: staged.source,
            config: staged.data,
            credentialPath: credentialLabel,
            executionMode: credentialSet.executionMode,
            windowsDirectory: windowsDirectory)
        else {
          return Self.credentialFailure(
            provider: provider.id,
            path: credentialLabel,
            source: .init(
              distributionLabel: resolved.distribution,
              kind: .manual(credentialLabel),
              isResolved: false),
            error: WindowsCanonicalCLIError.executableUnavailable,
            authorityCheck: authorityCheck)
        }
        return await self.cliClient.fetch(
          provider: provider.id,
          invocation: invocation,
          environmentOverrides: [:],
          authorityCheck: authorityCheck)
      } catch {
        return Self.credentialFailure(
          provider: provider.id,
          path: "Manual",
          source: .init(
            distributionLabel: resolved.distribution,
            kind: .manual(credentialRoute.manualLabel ?? "Manual credential"),
            isResolved: false),
          error: error,
          authorityCheck: authorityCheck)
      }
    }

    let environmentOverrides: [String: String]
    do {
      var bridgeEnvironment = self.environment
      if let authURL = WindowsWSLDefaultUserHome.openCodeAuthURL(
        distributionName: resolved.distribution)
      {
        bridgeEnvironment[WindowsProviderCredentialBridge.wslOpenCodeDataHomeEnvironmentKey] =
          authURL.deletingLastPathComponent().path
      }
      environmentOverrides = try self.credentialBridge.environmentOverrides(
        for: provider.id,
        base: bridgeEnvironment)
    } catch {
      return Self.credentialFailure(
        provider: provider.id,
        path: "OpenCode bridge",
        source: .init(
          distributionLabel: resolved.distribution,
          kind: .automatic,
          isResolved: false),
        error: error,
        authorityCheck: credentialRoute.check)
    }

    if !environmentOverrides.isEmpty {
      do {
        let config = try WindowsStagedProviderConfig.encodeBridge(
          provider: provider.id,
          companionValues: provider.companionValues)
        guard
          let invocation = await self.stagedInvocation(
            resolvedUsageCLI: resolved,
            provider: provider.id,
            source: "api",
            config: config,
            credentialPath: "OpenCode bridge",
            windowsDirectory: windowsDirectory)
        else {
          return Self.credentialFailure(
            provider: provider.id,
            path: "OpenCode bridge",
            source: .init(
              distributionLabel: resolved.distribution,
              kind: .openCode,
              isResolved: false),
            error: WindowsCanonicalCLIError.executableUnavailable,
            authorityCheck: credentialRoute.check)
        }
        return await self.cliClient.fetch(
          provider: provider.id,
          invocation: invocation,
          environmentOverrides: environmentOverrides,
          authorityCheck: credentialRoute.check)
      } catch {
        return Self.credentialFailure(
          provider: provider.id,
          path: "OpenCode bridge",
          source: .init(
            distributionLabel: resolved.distribution,
            kind: .openCode,
            isResolved: false),
          error: error,
          authorityCheck: credentialRoute.check)
      }
    }

    let automaticExecutionMode =
      WindowsProviderConfigurationCatalog.byProvider[provider.id]?.automaticExecutionMode ?? .usage
    guard
      let automaticCLI = await Self.resolveAutomaticCLI(
        resolvedUsageCLI: resolved,
        executionMode: automaticExecutionMode,
        bundled: { distribution in
          await self.bundledCLIDiscoveryCache.executablePath(
            distribution: distribution,
            windowsDirectory: windowsDirectory)
        })
    else {
      return Self.unavailable(
        provider,
        source: configuredSource,
        authorityCheck: credentialRoute.check)
    }
    let invocation = WindowsCanonicalCLIInvocation.wsl(
      distribution: automaticCLI.distribution,
      executablePath: automaticCLI.executablePath,
      providerID: provider.id.cliName,
      executionMode: automaticExecutionMode,
      windowsDirectory: windowsDirectory)
    return await self.cliClient.fetch(
      provider: provider.id,
      invocation: invocation,
      environmentOverrides: [:],
      authorityCheck: credentialRoute.check)
  }

  static func mergingEnvironmentOverrides(
    base: [String: String],
    overrides: [String: String]
  ) -> [String: String] {
    var merged = Dictionary(
      uniqueKeysWithValues: base.map { ($0.key.lowercased(), ($0.key, $0.value)) })
    for (key, value) in overrides {
      merged[key.lowercased()] = (key, value)
    }
    return Dictionary(uniqueKeysWithValues: merged.values.map { ($0.0, $0.1) })
  }

  private func resolvedCLI(
    distributions: [String],
    windowsDirectory: String
  ) async -> ResolvedCLI? {
    await Self.resolveCLI(
      distributions: distributions,
      existing: { distribution in
        await self.cliDiscoveryCache.executablePath(
          distribution: distribution,
          windowsDirectory: windowsDirectory)
      },
      bundled: { distribution in
        await self.bundledCLIDiscoveryCache.executablePath(
          distribution: distribution,
          windowsDirectory: windowsDirectory)
      })
  }

  // swiftlint:disable:next function_parameter_count
  private func stagedInvocation(
    resolvedUsageCLI: ResolvedCLI,
    provider: WindowsProviderID,
    source: String,
    config: Data,
    credentialPath: String,
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode = .usage,
    windowsDirectory: String
  ) async -> WindowsCanonicalCLIInvocation? {
    guard
      let bundledCLI = await self.bundledCLIDiscoveryCache.executablePath(
        distribution: resolvedUsageCLI.distribution,
        windowsDirectory: windowsDirectory)
    else { return nil }
    let launcherPath = URL(fileURLWithPath: bundledCLI).deletingLastPathComponent()
      .appendingPathComponent("CodexBarStagingLauncher", isDirectory: false).path
    return .stagedWSL(
      distribution: resolvedUsageCLI.distribution,
      launcherPath: launcherPath,
      providerID: provider.cliName,
      source: source,
      config: config,
      credentialPath: credentialPath,
      executionMode: executionMode,
      windowsDirectory: windowsDirectory)
  }

  struct ResolvedCLI: Equatable, Sendable {
    let distribution: String
    let executablePath: String
  }

  /// Existing user CLIs across every candidate win before CodexBar provisions its bundled helper.
  static func resolveCLI(
    distributions: [String],
    existing: @Sendable (_ distribution: String) async -> String?,
    bundled: @Sendable (_ distribution: String) async -> String?
  ) async -> ResolvedCLI? {
    var candidates: [String] = []
    var seen = Set<String>()
    for rawDistribution in distributions {
      let distribution = rawDistribution.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !distribution.isEmpty, seen.insert(distribution.lowercased()).inserted else { continue }
      candidates.append(distribution)
    }
    for distribution in candidates {
      if let executablePath = await existing(distribution) {
        return ResolvedCLI(distribution: distribution, executablePath: executablePath)
      }
    }
    for distribution in candidates {
      if let executablePath = await bundled(distribution) {
        return ResolvedCLI(distribution: distribution, executablePath: executablePath)
      }
    }
    return nil
  }

  static func resolveAutomaticCLI(
    resolvedUsageCLI: ResolvedCLI,
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode,
    bundled: @Sendable (_ distribution: String) async -> String?
  ) async -> ResolvedCLI? {
    guard executionMode == .diagnose else { return resolvedUsageCLI }
    guard let executablePath = await bundled(resolvedUsageCLI.distribution) else { return nil }
    return ResolvedCLI(
      distribution: resolvedUsageCLI.distribution,
      executablePath: executablePath)
  }

  static func candidateDistributions(
    for provider: WindowsProviderConfiguration,
    installed: [String]
  ) -> [String] {
    if provider.sourceMode == .wsl, let selected = Self.trimmed(provider.wslDistro) {
      return installed.first(where: {
        $0.caseInsensitiveCompare(selected) == .orderedSame
      }).map { [$0] } ?? [selected]
    }
    return installed
  }

  private static func unavailable(
    _ provider: WindowsProviderConfiguration,
    source: WindowsProviderSourcePresentation,
    authorityCheck: (@Sendable () throws -> Bool)?
  )
    -> WindowsProviderSnapshot
  {
    let snapshot = WindowsProviderSnapshot(
      provider: provider.id,
      availability: .unavailable,
      source: source,
      safeErrorText: "CodexBar CLI was not found in the selected WSL distribution.")
    return snapshot.requiringPublicationAuthority(authorityCheck)
  }

  private static func credentialFailure(
    provider: WindowsProviderID,
    path: String,
    source: WindowsProviderSourcePresentation,
    error: Error,
    authorityCheck: (@Sendable () throws -> Bool)? = nil,
    discardsRefreshResult: Bool = false
  ) -> WindowsProviderSnapshot {
    let snapshot = WindowsProviderSnapshot(
      provider: provider,
      availability: .error,
      source: source,
      safeErrorText: Self.safeCredentialError(error, path: path),
      discardsRefreshResult: discardsRefreshResult)
    return snapshot.requiringPublicationAuthority(authorityCheck)
  }

  private static func safeCredentialError(_ error: Error, path: String) -> String {
    let displayPath = path.replacingOccurrences(
      of: "OpenCode bridge",
      with: "OpenCode",
      options: .caseInsensitive)
    switch error {
    case let error as WindowsProviderCredentialVaultError:
      return error.errorDescription ?? "The \(displayPath.lowercased()) credential is unavailable."
    case let error as WindowsStagedProviderConfigError:
      return error.errorDescription ?? "The \(displayPath.lowercased()) configuration is invalid."
    case let error as WindowsProviderCredentialBridge.BridgeError:
      return error.errorDescription ?? "OpenCode is unavailable."
    default:
      return "The \(displayPath.lowercased()) provider request could not be completed."
    }
  }

  private static func providerOrder(
    _ lhs: WindowsProviderConfiguration,
    _ rhs: WindowsProviderConfiguration
  ) -> Bool {
    if lhs.order != rhs.order { return lhs.order < rhs.order }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

}

enum WindowsBoundedConcurrentMap {
  static func map<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    maximumConcurrentTasks: Int,
    operation: @escaping @Sendable (Input) async -> Output
  ) async -> [Output] {
    guard !inputs.isEmpty else { return [] }
    let limit = min(inputs.count, max(1, maximumConcurrentTasks))
    return await withTaskGroup(of: (Int, Output).self) { group in
      var results: [Int: Output] = [:]
      results.reserveCapacity(inputs.count)
      var nextIndex = 0

      for index in 0..<limit {
        group.addTask { (index, await operation(inputs[index])) }
        nextIndex += 1
      }

      while let (index, output) = await group.next() {
        results[index] = output
        if nextIndex < inputs.count {
          let index = nextIndex
          group.addTask { (index, await operation(inputs[index])) }
          nextIndex += 1
        }
      }

      return inputs.indices.map { index in
        guard let output = results[index] else {
          preconditionFailure("Bounded concurrent map lost output at index \(index)")
        }
        return output
      }
    }
  }
}

extension WindowsProviderSourceMode {
  var displayName: String {
    switch self {
    case .automatic:
      "Automatic"
    case .wsl:
      "WSL CLI"
    default:
      "Automatic"
    }
  }

}

extension WindowsProviderConfiguration {
  var sourceDisplayName: String {
    WindowsProviderSourcePresentation.configuredFallback(configuration: self).formattedValue
  }
}
