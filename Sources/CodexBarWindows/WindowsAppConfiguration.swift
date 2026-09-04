import Foundation

struct WindowsProviderSourceMode: RawRepresentable, Hashable, Codable, Sendable,
  CustomStringConvertible
{
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.rawValue)
  }

  var description: String { self.rawValue }

  static let automatic = Self(rawValue: "automatic")
  static let wsl = Self(rawValue: "wsl")
}

struct WindowsProviderConfiguration: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var id: WindowsProviderID
  var enabled: Bool
  var order: Int
  var sourceMode: WindowsProviderSourceMode
  var wslDistro: String?
  var companionValues: [String: String]

  init(
    id: WindowsProviderID,
    enabled: Bool,
    order: Int,
    sourceMode: WindowsProviderSourceMode = .automatic,
    wslDistro: String? = nil,
    companionValues: [String: String] = [:]
  ) {
    self.id = id
    self.enabled = enabled
    self.order = order
    self.sourceMode = sourceMode
    self.wslDistro = wslDistro
    self.companionValues = Self.sanitizedCompanionValues(companionValues, provider: id)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case enabled
    case order
    case sourceMode
    case wslDistro
    case companionValues
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WindowsProviderID.self, forKey: .id)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    self.order = try container.decodeIfPresent(Int.self, forKey: .order) ?? .max
    self.sourceMode =
      try container.decodeIfPresent(WindowsProviderSourceMode.self, forKey: .sourceMode)
      ?? .automatic
    self.wslDistro = try container.decodeIfPresent(String.self, forKey: .wslDistro)
    let decodedCompanionValues =
      try container.decodeIfPresent(
        [String: String].self,
        forKey: .companionValues) ?? [:]
    self.companionValues = Self.sanitizedCompanionValues(decodedCompanionValues, provider: self.id)
  }

  var description: String {
    "WindowsProviderConfiguration(id: \(self.id), enabled: \(self.enabled), order: \(self.order), "
      + "sourceMode: \(self.sourceMode), wslDistributionConfigured: \(self.wslDistro != nil))"
  }

  var debugDescription: String { self.description }

  private static func sanitizedCompanionValues(
    _ values: [String: String],
    provider: WindowsProviderID
  ) -> [String: String] {
    guard let schema = WindowsProviderConfigurationCatalog.byProvider[provider] else { return [:] }
    let permittedIDs = Set(
      schema.credentialSets.lazy.flatMap(\.fields).filter { !$0.secret }.map(\.id))
    return values.filter { permittedIDs.contains($0.key) }
  }
}

struct WindowsAppConfiguration: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  static let currentSchemaVersion = 7
  static let defaultRefreshIntervalMinutes = 5
  static let allowedRefreshIntervalMinutes = 1...1440

  var schemaVersion: Int
  var usageBarsShowUsed: Bool
  var refreshIntervalMinutes: Int
  var runAtStartup: Bool
  var providers: [WindowsProviderConfiguration]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    usageBarsShowUsed: Bool = false,
    refreshIntervalMinutes: Int = Self.defaultRefreshIntervalMinutes,
    runAtStartup: Bool = false,
    providers: [WindowsProviderConfiguration]
  ) {
    self.schemaVersion = schemaVersion
    self.usageBarsShowUsed = usageBarsShowUsed
    self.refreshIntervalMinutes = Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes)
    self.runAtStartup = runAtStartup
    self.providers = providers
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case usageBarsShowUsed
    case refreshIntervalMinutes
    case runAtStartup
    case providers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    self.usageBarsShowUsed =
      try container.decodeIfPresent(Bool.self, forKey: .usageBarsShowUsed) ?? false
    self.refreshIntervalMinutes = Self.normalizedRefreshIntervalMinutes(
      try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
        ?? Self.defaultRefreshIntervalMinutes)
    self.runAtStartup = try container.decodeIfPresent(Bool.self, forKey: .runAtStartup) ?? false
    self.providers =
      try container.decodeIfPresent([WindowsProviderConfiguration].self, forKey: .providers) ?? []
  }

  static var defaults: Self {
    let preferred = WindowsProviderID.initiallyEnabledProviders
    let preferredSet = Set(preferred)
    let orderedEntries =
      preferred.compactMap { WindowsProviderCatalog.byID[$0] }
      + WindowsProviderCatalog.entries.filter { !preferredSet.contains($0.id) }.sorted {
        let lhs = WindowsProviderConfiguration(id: $0.id, enabled: false, order: 0)
        let rhs = WindowsProviderConfiguration(id: $1.id, enabled: false, order: 0)
        return WindowsProviderSettingsSearch.alphabeticalOrder(lhs, rhs)
      }
    return Self(
      providers: orderedEntries.enumerated().map { offset, entry in
        WindowsProviderConfiguration(
          id: entry.id,
          enabled: preferredSet.contains(entry.id),
          order: offset)
      })
  }

  /// Adds newly catalogued providers without discarding unknown providers written by a newer build.
  func mergingCatalogDefaults() -> Self {
    var result = self
    let shouldAlphabetizeDisabledProviders = result.schemaVersion < 7
    var seen = Set(self.providers.map(\.id))
    var nextOrder = (self.providers.map(\.order).max() ?? -1) + 1

    for entry in WindowsProviderCatalog.entries where seen.insert(entry.id).inserted {
      result.providers.append(.init(id: entry.id, enabled: false, order: nextOrder))
      nextOrder += 1
    }

    result.providers =
      shouldAlphabetizeDisabledProviders
      ? Self.alphabetizingDisabledProviders(result.providers)
      : Self.sectionedProviders(result.providers)
    if result.schemaVersion < Self.currentSchemaVersion {
      result.schemaVersion = Self.currentSchemaVersion
    }
    return result
  }

  var description: String {
    "WindowsAppConfiguration(schemaVersion: \(self.schemaVersion), usageBarsShowUsed: "
      + "\(self.usageBarsShowUsed), refreshIntervalMinutes: \(self.refreshIntervalMinutes), "
      + "runAtStartup: \(self.runAtStartup), "
      + "providers: \(self.providers.count))"
  }

  var debugDescription: String { self.description }

  var orderedProviders: [WindowsProviderConfiguration] {
    self.providers.sorted {
      if $0.order != $1.order { return $0.order < $1.order }
      return $0.id.rawValue < $1.id.rawValue
    }
  }

  var enabledProviders: [WindowsProviderConfiguration] {
    self.orderedProviders.filter(\.enabled)
  }

  var disabledProviders: [WindowsProviderConfiguration] {
    self.orderedProviders.filter { !$0.enabled }
  }

  var enabledProviderIDs: [WindowsProviderID] {
    self.enabledProviders.map(\.id)
  }

  @discardableResult
  mutating func setProviderEnabled(_ provider: WindowsProviderID, enabled: Bool) -> Bool {
    let ordered = self.orderedProviders
    guard var changed = ordered.first(where: { $0.id == provider }), changed.enabled != enabled
    else {
      return false
    }

    var enabledProviders = ordered.filter { $0.enabled && $0.id != provider }
    var disabledProviders = ordered.filter { !$0.enabled && $0.id != provider }
    changed.enabled = enabled
    if enabled {
      enabledProviders.append(changed)
    } else {
      disabledProviders.insert(changed, at: 0)
    }
    self.providers = Self.assigningOrders(to: enabledProviders + disabledProviders)
    return true
  }

  static func parsedRefreshIntervalMinutes(_ text: String) -> Int? {
    guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      Self.allowedRefreshIntervalMinutes.contains(minutes)
    else {
      return nil
    }
    return minutes
  }

  private static func normalizedRefreshIntervalMinutes(_ minutes: Int) -> Int {
    min(
      Self.allowedRefreshIntervalMinutes.upperBound,
      max(Self.allowedRefreshIntervalMinutes.lowerBound, minutes))
  }

  private static func sectionedProviders(_ providers: [WindowsProviderConfiguration])
    -> [WindowsProviderConfiguration]
  {
    let ordered = providers.sorted {
      if $0.order != $1.order { return $0.order < $1.order }
      return $0.id.rawValue < $1.id.rawValue
    }
    return self.assigningOrders(
      to: ordered.filter(\.enabled) + ordered.filter { !$0.enabled })
  }

  private static func alphabetizingDisabledProviders(
    _ providers: [WindowsProviderConfiguration]
  ) -> [WindowsProviderConfiguration] {
    let ordered = providers.sorted {
      if $0.order != $1.order { return $0.order < $1.order }
      return $0.id.rawValue < $1.id.rawValue
    }
    return self.assigningOrders(
      to: ordered.filter(\.enabled)
        + ordered.filter { !$0.enabled }.sorted(by: WindowsProviderSettingsSearch.alphabeticalOrder)
    )
  }

  private static func assigningOrders(to providers: [WindowsProviderConfiguration])
    -> [WindowsProviderConfiguration]
  {
    providers.enumerated().map { order, provider in
      var provider = provider
      provider.order = order
      return provider
    }
  }
}

enum WindowsConfigurationStoreError: Error, Equatable, LocalizedError {
  case localAppDataUnavailable

  var errorDescription: String? {
    switch self {
    case .localAppDataUnavailable:
      "LOCALAPPDATA is unavailable; CodexBar cannot resolve its Windows configuration directory."
    }
  }
}

struct WindowsConfigurationStore: Sendable {
  let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard
      let localAppData = environment["LOCALAPPDATA"]?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !localAppData.isEmpty
    else {
      throw WindowsConfigurationStoreError.localAppDataUnavailable
    }
    self.fileURL = URL(fileURLWithPath: localAppData, isDirectory: true)
      .appendingPathComponent("CodexBar", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  func load(fileManager: FileManager = .default) throws -> WindowsAppConfiguration {
    guard fileManager.fileExists(atPath: self.fileURL.path) else {
      return .defaults
    }
    let data = try Data(contentsOf: self.fileURL)
    let decoded = try JSONDecoder().decode(WindowsAppConfiguration.self, from: data)
    let merged = decoded.mergingCatalogDefaults()
    if merged != decoded {
      try? self.save(merged, fileManager: fileManager)
    }
    return merged
  }

  /// `Data.write(.atomic)` writes a sibling temporary file and replaces the destination only
  /// after the complete JSON payload has been written.
  func save(_ configuration: WindowsAppConfiguration, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: self.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    try data.write(to: self.fileURL, options: .atomic)
  }
}
