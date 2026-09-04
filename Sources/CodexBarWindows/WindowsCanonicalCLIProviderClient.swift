import Foundation

enum WindowsCanonicalCLIError: LocalizedError, Sendable {
  case executableUnavailable
  case launchFailed
  case timedOut
  case outputTooLarge
  case invalidEnvironment
  case commandFailed(Int32)
  case invalidPayload
  case providerMismatch
  case staleCredential
  case cancelled

  var errorDescription: String? {
    switch self {
    case .executableUnavailable:
      "Configured CodexBar CLI was not found."
    case .launchFailed:
      "CodexBar CLI could not be started."
    case .timedOut:
      "CodexBar CLI timed out."
    case .outputTooLarge:
      "CodexBar CLI returned too much data."
    case .invalidEnvironment:
      "CodexBar CLI received an invalid process environment."
    case .commandFailed(let status):
      "CodexBar CLI exited with status \(status)."
    case .invalidPayload:
      "CodexBar CLI returned invalid usage data."
    case .providerMismatch:
      "CodexBar CLI returned data for a different provider."
    case .staleCredential:
      "The provider credential changed while usage was loading."
    case .cancelled:
      "The provider request was cancelled."
    }
  }
}

struct WindowsCanonicalCLIInvocation: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  static let diagnosticProcessTimeout: TimeInterval = 90
  static let stagedDiagnosticLauncherTimeoutSeconds = 75
  static let stagedUsageLauncherTimeoutSeconds = 50

  enum ExecutionMode: String, Equatable, Sendable {
    case usage
    case diagnose
  }

  let executablePath: String
  let arguments: [String]
  let source: WindowsProviderSourcePresentation
  let distribution: String
  let standardInput: Data?
  let allowsRetry: Bool
  let executionMode: ExecutionMode

  init(
    executablePath: String,
    arguments: [String],
    source: WindowsProviderSourcePresentation,
    distribution: String,
    standardInput: Data?,
    allowsRetry: Bool,
    executionMode: ExecutionMode = .usage
  ) {
    self.executablePath = executablePath
    self.arguments = arguments
    self.source = source
    self.distribution = distribution
    self.standardInput = standardInput
    self.allowsRetry = allowsRetry
    self.executionMode = executionMode
  }

  init(
    executablePath: String,
    arguments: [String],
    sourceText: String,
    distribution: String,
    standardInput: Data?,
    allowsRetry: Bool,
    executionMode: ExecutionMode = .usage
  ) {
    self.init(
      executablePath: executablePath,
      arguments: arguments,
      source: .compatibility(sourceText),
      distribution: distribution,
      standardInput: standardInput,
      allowsRetry: allowsRetry,
      executionMode: executionMode)
  }

  var sourceText: String { self.source.formattedValue }

  var description: String {
    "WindowsCanonicalCLIInvocation(distribution: \(self.distribution), staged: "
      + "\(self.standardInput != nil), mode: \(self.executionMode.rawValue), "
      + "arguments: \(self.arguments.count))"
  }

  var debugDescription: String { self.description }

  var usesWSL: Bool {
    URL(fileURLWithPath: self.executablePath).lastPathComponent
      .caseInsensitiveCompare("wsl.exe") == .orderedSame
  }

  var processTimeout: TimeInterval {
    if self.executionMode == .diagnose { return Self.diagnosticProcessTimeout }
    return self.standardInput == nil ? 45 : 60
  }

  static func wsl(
    distribution: String,
    executablePath: String,
    providerID: String,
    executionMode: ExecutionMode = .usage,
    windowsDirectory: String = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
  ) -> Self {
    let commandArguments =
      switch executionMode {
      case .usage:
        ["usage", "--provider", providerID, "--json-only"]
      case .diagnose:
        ["diagnose", "--provider", providerID, "--format", "json", "--redact"]
      }
    return Self(
      executablePath: URL(fileURLWithPath: windowsDirectory)
        .appendingPathComponent("System32/wsl.exe").path,
      arguments: ["-d", distribution, "--", executablePath] + commandArguments,
      source: .init(distributionLabel: distribution, kind: .automatic, isResolved: false),
      distribution: distribution,
      standardInput: nil,
      allowsRetry: true,
      executionMode: executionMode)
  }

  static func stagedWSL(
    distribution: String,
    launcherPath: String,
    providerID: String,
    source: String,
    config: Data,
    credentialPath: String,
    executionMode: ExecutionMode = .usage,
    windowsDirectory: String = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
  ) -> Self {
    let launcherTimeout =
      executionMode == .diagnose
      ? Self.stagedDiagnosticLauncherTimeoutSeconds : Self.stagedUsageLauncherTimeoutSeconds
    return Self(
      executablePath: URL(fileURLWithPath: windowsDirectory)
        .appendingPathComponent("System32/wsl.exe").path,
      arguments: [
        "-d", distribution, "--", launcherPath,
        "--timeout-seconds", String(launcherTimeout), "--provider", providerID, "--source", source,
        "--mode", executionMode.rawValue,
      ],
      source: .init(
        distributionLabel: distribution,
        kind: credentialPath == "OpenCode bridge" ? .openCode : .manual(credentialPath),
        isResolved: false),
      distribution: distribution,
      standardInput: config,
      allowsRetry: true,
      executionMode: executionMode)
  }
}

struct WindowsCanonicalCLIProviderClient: Sendable {
  typealias ProcessRunner =
    @Sendable (
      _ executablePath: String,
      _ arguments: [String],
      _ timeout: TimeInterval,
      _ maximumOutputBytes: Int,
      _ environmentOverrides: [String: String],
      _ standardInput: Data?
    ) throws -> WindowsHiddenProcessResult
  typealias RetryDelay = @Sendable () async throws -> Void

  private static let maximumOutputBytes = 1_048_576
  private static let wslExecutableNames = ["codexbar"]
  private let processRunner: ProcessRunner
  private let retryDelay: RetryDelay

  init(
    processRunner: @escaping ProcessRunner = {
      executablePath, arguments, timeout, maximumOutputBytes,
      environmentOverrides, standardInput in
      try WindowsHiddenProcessRunner.run(
        executablePath: executablePath,
        arguments: arguments,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes,
        environmentOverrides: environmentOverrides,
        standardInput: standardInput)
    },
    retryDelay: @escaping RetryDelay = {
      try await ContinuousClock().sleep(for: .seconds(2))
    }
  ) {
    self.processRunner = processRunner
    self.retryDelay = retryDelay
  }

  func fetch(
    provider: WindowsProviderID,
    invocation: WindowsCanonicalCLIInvocation,
    environmentOverrides: [String: String] = [:],
    authorityCheck: (@Sendable () throws -> Bool)? = nil
  ) async
    -> WindowsProviderSnapshot
  {
    do {
      return try await self.load(
        provider: provider,
        invocation: invocation,
        environmentOverrides: environmentOverrides,
        authorityCheck: authorityCheck)
    } catch {
      let error: Error = error is CancellationError ? WindowsCanonicalCLIError.cancelled : error
      let discardsRefreshResult =
        if let error = error as? WindowsCanonicalCLIError {
          switch error {
          case .staleCredential, .cancelled: true
          default: false
          }
        } else {
          false
        }
      let snapshot = WindowsProviderSnapshot(
        provider: provider,
        availability: .unavailable,
        source: invocation.source,
        safeErrorText: Self.safeMessage(error, source: invocation.sourceText),
        discardsRefreshResult: discardsRefreshResult)
      return discardsRefreshResult
        ? snapshot
        : snapshot.requiringPublicationAuthority(authorityCheck)
    }
  }

  func discoverWSLExecutablePath(
    distribution: String,
    windowsDirectory: String
  ) async -> String? {
    return await Task.detached(priority: .utility) {
      for executableName in Self.wslExecutableNames {
        let discovery = WindowsCanonicalCLIInvocation(
          executablePath: URL(fileURLWithPath: windowsDirectory)
            .appendingPathComponent("System32/wsl.exe").path,
          arguments: ["-d", distribution, "--", "/usr/bin/which", executableName],
          sourceText: "WSL CLI · \(distribution)",
          distribution: distribution,
          standardInput: nil,
          allowsRetry: false)
        if let result = try? self.run(invocation: discovery),
          let path = Self.discoveredExecutablePath(result)
        {
          return path
        }
      }
      let wslExecutable = URL(fileURLWithPath: windowsDirectory)
        .appendingPathComponent("System32/wsl.exe").path
      let homeDiscovery = WindowsCanonicalCLIInvocation(
        executablePath: wslExecutable,
        arguments: ["-d", distribution, "--", "/usr/bin/printenv", "HOME"],
        sourceText: "WSL CLI · \(distribution)",
        distribution: distribution,
        standardInput: nil,
        allowsRetry: false)
      let home = (try? self.run(invocation: homeDiscovery)).flatMap(Self.discoveredLinuxHome)
      let fixedDirectories = ["/usr/local/bin", "/usr/bin", "/home/linuxbrew/.linuxbrew/bin"]
      let homeDirectories =
        home.map { ["\($0)/.local/bin", "\($0)/bin", "\($0)/.linuxbrew/bin"] } ?? []
      for directory in fixedDirectories + homeDirectories {
        for executableName in Self.wslExecutableNames {
          let candidate = "\(directory)/\(executableName)"
          let executableCheck = WindowsCanonicalCLIInvocation(
            executablePath: wslExecutable,
            arguments: ["-d", distribution, "--", "/usr/bin/test", "-x", candidate],
            sourceText: "WSL CLI · \(distribution)",
            distribution: distribution,
            standardInput: nil,
            allowsRetry: false)
          if (try? self.run(invocation: executableCheck)) != nil {
            return candidate
          }
        }
      }
      return nil
    }.value
  }

  static func decode(
    data: Data,
    requestedProvider: WindowsProviderID,
    source: WindowsProviderSourcePresentation,
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode
  ) throws -> WindowsProviderSnapshot {
    switch executionMode {
    case .usage:
      try self.decode(data: data, requestedProvider: requestedProvider, source: source)
    case .diagnose:
      try WindowsProviderDiagnosticDecoder.decode(
        data: data,
        requestedProvider: requestedProvider,
        source: source)
    }
  }

  static func decode(
    data: Data,
    requestedProvider: WindowsProviderID,
    source: WindowsProviderSourcePresentation
  ) throws -> WindowsProviderSnapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(Self.decodeDate)
    let payloads: [Payload]
    if let array = try? decoder.decode([Payload].self, from: data) {
      payloads = array
    } else if let payload = try? decoder.decode(Payload.self, from: data) {
      payloads = [payload]
    } else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    guard let payload = payloads.first(where: { $0.provider == requestedProvider.rawValue }) else {
      throw WindowsCanonicalCLIError.providerMismatch
    }
    if let error = payload.error {
      return WindowsProviderSnapshot(
        provider: requestedProvider,
        availability: .error,
        source: source,
        safeErrorText: error.message.isEmpty
          ? "Provider usage is unavailable."
          : "Provider usage is unavailable in the configured CLI source.")
    }
    guard payload.usage != nil || payload.credits != nil else {
      throw WindowsCanonicalCLIError.invalidPayload
    }

    var windows: [WindowsProviderWindowSnapshot] = []
    Self.append(payload.usage?.primary, defaultLabel: "Session", to: &windows)
    Self.append(payload.usage?.secondary, defaultLabel: "Weekly", to: &windows)
    Self.append(payload.usage?.tertiary, defaultLabel: "Monthly", to: &windows)
    for extra in payload.usage?.extraRateWindows ?? [] where extra.usageKnown != false {
      Self.append(extra.window, defaultLabel: extra.title, to: &windows)
    }
    var balanceText = payload.credits.map {
      "\(Self.number($0.remaining)) credits remaining"
    }
    let identityText = Self.normalized(payload.usage?.identity?.loginMethod)
    let planText: String?
    if let identityText, let balance = Self.identityBalance(identityText) {
      balanceText = balanceText ?? balance
      planText = nil
    } else {
      planText = identityText
    }
    let accountText = Self.normalized(payload.account)
    let updatedAt = payload.usage?.updatedAt ?? payload.credits?.updatedAt ?? Date()
    return WindowsProviderSnapshot(
      provider: requestedProvider,
      availability: .available,
      usedPercent: windows.first?.usedPercent,
      resetText: windows.first?.resetText,
      source: source.resolvingUpstream(payload.source, provider: requestedProvider),
      windows: windows,
      planText: planText.map { "Plan: \($0)" },
      balanceText: balanceText,
      accountText: accountText,
      updatedAt: updatedAt)
  }

  static func decode(
    data: Data,
    requestedProvider: WindowsProviderID,
    sourceText: String
  ) throws -> WindowsProviderSnapshot {
    try self.decode(
      data: data,
      requestedProvider: requestedProvider,
      source: .compatibility(sourceText))
  }

  private func run(
    invocation: WindowsCanonicalCLIInvocation,
    environmentOverrides: [String: String] = [:]
  ) throws -> Data {
    let result = try self.processRunner(
      invocation.executablePath,
      invocation.arguments,
      invocation.processTimeout,
      Self.maximumOutputBytes,
      environmentOverrides,
      invocation.standardInput)
    guard result.exitCode == 0 else {
      throw WindowsCanonicalCLIError.commandFailed(result.exitCode)
    }
    return result.standardOutput
  }

  private func load(
    provider: WindowsProviderID,
    invocation: WindowsCanonicalCLIInvocation,
    environmentOverrides: [String: String],
    authorityCheck: (@Sendable () throws -> Bool)?
  ) async throws -> WindowsProviderSnapshot {
    var hasRetried = false
    while true {
      let attempt: ProviderAttempt
      do {
        attempt = try await self.performAttempt(
          provider: provider,
          invocation: invocation,
          environmentOverrides: environmentOverrides,
          authorityCheck: authorityCheck)
      } catch {
        guard invocation.allowsRetry, !hasRetried,
          let error = error as? WindowsCanonicalCLIError,
          Self.shouldRetry(error)
        else { throw error }
        try await self.waitForRetry()
        hasRetried = true
        continue
      }
      guard invocation.allowsRetry, !hasRetried, attempt.shouldRetry else {
        return attempt.snapshot
      }
      try await self.waitForRetry()
      hasRetried = true
    }
  }

  private func performAttempt(
    provider: WindowsProviderID,
    invocation: WindowsCanonicalCLIInvocation,
    environmentOverrides: [String: String],
    authorityCheck: (@Sendable () throws -> Bool)?
  ) async throws -> ProviderAttempt {
    let operation = Task.detached(priority: .utility) {
      try WindowsProviderOperationLock.withLock(provider: provider) {
        guard try authorityCheck?() ?? true else {
          throw WindowsCanonicalCLIError.staleCredential
        }
        let data = try self.run(
          invocation: invocation,
          environmentOverrides: environmentOverrides)
        guard try authorityCheck?() ?? true else {
          throw WindowsCanonicalCLIError.staleCredential
        }
        let attempt = try Self.decodeAttempt(
          data: data,
          requestedProvider: provider,
          source: invocation.source,
          executionMode: invocation.executionMode)
        return ProviderAttempt(
          snapshot: attempt.snapshot.requiringPublicationAuthority(authorityCheck),
          shouldRetry: attempt.shouldRetry)
      }
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private func waitForRetry() async throws {
    do {
      try Task.checkCancellation()
      try await self.retryDelay()
      try Task.checkCancellation()
    } catch is CancellationError {
      throw WindowsCanonicalCLIError.cancelled
    }
  }

  private static func decodeAttempt(
    data: Data,
    requestedProvider: WindowsProviderID,
    source: WindowsProviderSourcePresentation,
    executionMode: WindowsCanonicalCLIInvocation.ExecutionMode
  ) throws -> ProviderAttempt {
    switch executionMode {
    case .usage:
      return ProviderAttempt(
        snapshot: try self.decode(
          data: data,
          requestedProvider: requestedProvider,
          source: source),
        shouldRetry: false)
    case .diagnose:
      let result = try WindowsProviderDiagnosticDecoder.decodeResult(
        data: data,
        requestedProvider: requestedProvider,
        source: source)
      return ProviderAttempt(snapshot: result.snapshot, shouldRetry: result.shouldRetry)
    }
  }

  static func shouldRetry(_ error: WindowsCanonicalCLIError) -> Bool {
    switch error {
    case .timedOut, .commandFailed:
      true
    case .executableUnavailable, .launchFailed, .outputTooLarge, .invalidEnvironment,
      .invalidPayload, .providerMismatch, .staleCredential, .cancelled:
      false
    }
  }

  private struct ProviderAttempt: Sendable {
    let snapshot: WindowsProviderSnapshot
    let shouldRetry: Bool
  }

  static func discoveredExecutablePath(_ data: Data) -> String? {
    let value =
      String(decoding: data, as: UTF8.self)
      .components(separatedBy: .newlines).first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard value.hasPrefix("/"), value.count <= 4096,
      !value.unicodeScalars.contains(where: { $0.value < 32 }),
      Self.isCanonicalExecutableName(URL(fileURLWithPath: value).lastPathComponent)
    else { return nil }
    return value
  }

  static func discoveredLinuxHome(_ data: Data) -> String? {
    let value =
      String(decoding: data, as: UTF8.self)
      .components(separatedBy: .newlines).first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard value.hasPrefix("/"), value.count <= 4096,
      !value.unicodeScalars.contains(where: { $0.value < 32 })
    else { return nil }
    return value.hasSuffix("/") ? String(value.dropLast()) : value
  }

  private static func isCanonicalExecutableName(_ value: String) -> Bool {
    value.caseInsensitiveCompare("codexbar") == .orderedSame
  }

  private static func append(
    _ window: RateWindow?,
    defaultLabel: String,
    to windows: inout [WindowsProviderWindowSnapshot]
  ) {
    guard let window, window.isSyntheticPlaceholder != true else { return }
    let label = Self.normalized(window.label) ?? defaultLabel
    windows.append(
      WindowsProviderWindowSnapshot(
        label: label,
        usedPercent: min(100, max(0, window.usedPercent)),
        resetText: WindowsResetLabelFormatter.label(
          resetsAt: window.resetsAt,
          description: window.resetDescription),
        resetsAt: window.resetsAt))
  }

  private static func decodeDate(_ decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
  }

  private static func number(_ value: Double) -> String {
    if abs(value - value.rounded()) < 0.000_001 {
      return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private static func identityBalance(_ value: String) -> String? {
    let prefixes = ["Balance:", "Credits:", "Points:"]
    let balance: String
    if let prefix = prefixes.first(where: {
      value.range(of: $0, options: [.anchored, .caseInsensitive]) != nil
    }) {
      balance = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if value.range(
      of: #"^[0-9][0-9,.]*\s+(?:points?|credits?)$"#,
      options: [.regularExpression, .caseInsensitive]) != nil
    {
      balance = value
    } else {
      return nil
    }
    guard !balance.isEmpty else { return nil }
    return balance.lowercased().hasSuffix(" remaining")
      ? String(balance)
      : "\(balance) remaining"
  }

  private static func normalized(_ value: String?, fallback: String? = nil) -> String? {
    guard let value else { return fallback }
    let result =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return result.isEmpty ? fallback : String(result.prefix(300))
  }

  private static func safeMessage(_ error: Error, source: String) -> String {
    if let error = error as? WindowsCanonicalCLIError {
      switch error {
      case .executableUnavailable:
        return "\(source) was not found."
      case .launchFailed:
        return "\(source) could not be started."
      case .timedOut:
        return "\(source) took too long to respond."
      case .outputTooLarge:
        return "\(source) returned more data than CodexBar can safely read."
      case .invalidEnvironment:
        return "\(source) could not start with the selected credential source."
      case .commandFailed(let status):
        return "\(source) stopped with exit code \(status)."
      case .invalidPayload:
        return "\(source) returned usage data CodexBar could not understand."
      case .providerMismatch:
        return "\(source) returned usage for a different provider."
      case .staleCredential:
        return "Credentials changed while \(source) was loading. Refresh again."
      case .cancelled:
        return "\(source) was cancelled because its credentials changed."
      }
    }
    return "Usage could not be loaded from \(source)."
  }

  private struct Payload: Decodable {
    let provider: String
    let source: String?
    let account: String?
    let usage: Usage?
    let credits: Credits?
    let error: ErrorPayload?
  }

  private struct Usage: Decodable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let extraRateWindows: [NamedRateWindow]?
    let updatedAt: Date?
    let identity: Identity?
  }

  private struct RateWindow: Decodable {
    let label: String?
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?
    let isSyntheticPlaceholder: Bool?
  }

  private struct NamedRateWindow: Decodable {
    let title: String
    let window: RateWindow
    let usageKnown: Bool?
  }

  private struct Identity: Decodable {
    let loginMethod: String?
  }

  private struct Credits: Decodable {
    let remaining: Double
    let updatedAt: Date?
  }

  private struct ErrorPayload: Decodable {
    let message: String
  }
}
