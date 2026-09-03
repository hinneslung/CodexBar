import Foundation

/// Coalesces canonical CLI discovery so one refresh does not probe the same WSL distribution once
/// per enabled provider. Missing paths expire quickly so installing the CLI does not require an app
/// restart; successful paths are stable enough to reuse for the session.
actor WindowsCanonicalCLIDiscoveryCache {
  typealias Resolver =
    @Sendable (_ distribution: String, _ windowsDirectory: String) async -> String?

  private struct Key: Hashable, Sendable {
    let distribution: String
    let windowsDirectory: String
  }

  private struct Entry: Sendable {
    let executablePath: String?
    let expiresAt: Date
  }

  private let positiveLifetime: TimeInterval
  private let negativeLifetime: TimeInterval
  private let now: @Sendable () -> Date
  private let resolver: Resolver
  private var entries: [Key: Entry] = [:]
  private var inFlight: [Key: Task<String?, Never>] = [:]

  init(
    positiveLifetime: TimeInterval = 6 * 60 * 60,
    negativeLifetime: TimeInterval = 10 * 60,
    now: @escaping @Sendable () -> Date = Date.init,
    resolver: @escaping Resolver = { distribution, windowsDirectory in
      await WindowsCanonicalCLIProviderClient().discoverWSLExecutablePath(
        distribution: distribution,
        windowsDirectory: windowsDirectory)
    }
  ) {
    self.positiveLifetime = positiveLifetime
    self.negativeLifetime = negativeLifetime
    self.now = now
    self.resolver = resolver
  }

  func executablePath(distribution: String, windowsDirectory: String) async -> String? {
    let key = Key(
      distribution: distribution.lowercased(),
      windowsDirectory: windowsDirectory.lowercased())
    let currentTime = self.now()
    if let entry = self.entries[key], entry.expiresAt > currentTime {
      return entry.executablePath
    }
    if let task = self.inFlight[key] {
      return await task.value
    }

    let resolver = self.resolver
    let task = Task { await resolver(distribution, windowsDirectory) }
    self.inFlight[key] = task
    let executablePath = await task.value
    self.inFlight.removeValue(forKey: key)
    let lifetime = executablePath == nil ? self.negativeLifetime : self.positiveLifetime
    self.entries[key] = Entry(
      executablePath: executablePath,
      expiresAt: self.now().addingTimeInterval(lifetime))
    return executablePath
  }
}
