import Foundation

struct WindowsProviderProfileID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    static let maximumBytes = 64
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid provider profile ID"))
        }
        self.init(rawValue: value)
    }

    func encode(to encoder: Encoder) throws {
        guard Self.isValid(self.rawValue) else {
            throw EncodingError.invalidValue(
                self.rawValue,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid provider profile ID"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    var description: String {
        self.rawValue
    }

    static func defaultID(for provider: WindowsProviderID) -> Self {
        Self(rawValue: provider.rawValue)
    }

    static func new() -> Self {
        Self(rawValue: Foundation.UUID().uuidString.lowercased())
    }

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= self.maximumBytes else { return false }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...122).contains($0.value) || $0.value == 45
        }
    }
}

enum WindowsProviderProfileValidation {
    static let defaultName = "Default"
    static let maximumNameCharacters = 40
    static let maximumCodexHomeCharacters = 512

    static func normalizedName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= self.maximumNameCharacters,
              self.isDisplaySafe(normalized)
        else { return nil }
        return normalized
    }

    static func hasDuplicateName(
        _ profile: WindowsProviderConfiguration,
        among profiles: [WindowsProviderConfiguration]) -> Bool
    {
        profiles.contains {
            $0.id == profile.id && $0.profileID != profile.profileID
                && $0.profileName.caseInsensitiveCompare(profile.profileName) == .orderedSame
        }
    }

    static func normalizedCodexHome(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count <= self.maximumCodexHomeCharacters,
              self.isDisplaySafe(normalized), !normalized.contains("\\"),
              normalized.hasPrefix("/") || normalized.hasPrefix("~/"),
              !normalized.contains(where: { ";|&<>$`\"'".contains($0) }),
              !normalized.split(separator: "/", omittingEmptySubsequences: true)
                  .contains(where: { $0 == "." || $0 == ".." })
        else { return nil }
        return normalized
    }

    static func isDisplaySafe(_ value: String) -> Bool {
        !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
        }
    }
}

struct WindowsProviderSourceMode: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    var description: String {
        self.rawValue
    }

    static let automatic = Self(rawValue: "automatic")
    static let wsl = Self(rawValue: "wsl")
}

struct WindowsProviderConfiguration: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    var id: WindowsProviderID
    var profileID: WindowsProviderProfileID
    var profileName: String
    var enabled: Bool
    var order: Int
    var sourceMode: WindowsProviderSourceMode
    var wslDistro: String?
    var companionValues: [String: String]
    var codexHome: String?

    init(
        id: WindowsProviderID,
        profileID: WindowsProviderProfileID? = nil,
        profileName: String = WindowsProviderProfileValidation.defaultName,
        enabled: Bool,
        order: Int,
        sourceMode: WindowsProviderSourceMode = .automatic,
        wslDistro: String? = nil,
        companionValues: [String: String] = [:],
        codexHome: String? = nil)
    {
        self.id = id
        self.profileID = profileID ?? .defaultID(for: id)
        self.profileName = WindowsProviderProfileValidation.normalizedName(profileName)
            ?? WindowsProviderProfileValidation.defaultName
        self.enabled = enabled
        self.order = order
        self.sourceMode = sourceMode
        self.wslDistro = wslDistro
        self.companionValues = Self.sanitizedCompanionValues(companionValues, provider: id)
        if id == .codex, let codexHome {
            let trimmedHome = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
            self.codexHome = trimmedHome.isEmpty ? nil : trimmedHome
        } else {
            self.codexHome = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case profileID
        case profileName
        case enabled
        case order
        case sourceMode
        case wslDistro
        case companionValues
        case codexHome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(WindowsProviderID.self, forKey: .id)
        self.profileID = try container.decodeIfPresent(WindowsProviderProfileID.self, forKey: .profileID)
            ?? .defaultID(for: self.id)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .profileName)
            ?? WindowsProviderProfileValidation.defaultName
        guard let profileName = WindowsProviderProfileValidation.normalizedName(decodedName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .profileName, in: container, debugDescription: "Invalid provider profile name")
        }
        self.profileName = profileName
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
        let decodedCodexHome = try container.decodeIfPresent(String.self, forKey: .codexHome)
        if let decodedCodexHome,
           WindowsProviderProfileValidation.normalizedCodexHome(decodedCodexHome) == nil,
           !decodedCodexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw DecodingError.dataCorruptedError(
                forKey: .codexHome, in: container, debugDescription: "Invalid Codex home")
        }
        self.codexHome = self.id == .codex
            ? WindowsProviderProfileValidation.normalizedCodexHome(decodedCodexHome)
            : nil
    }

    var description: String {
        "WindowsProviderConfiguration(id: \(self.id), profileID: \(self.profileID), "
            + "enabled: \(self.enabled), order: \(self.order), "
            + "sourceMode: \(self.sourceMode), wslDistributionConfigured: \(self.wslDistro != nil))"
    }

    var debugDescription: String {
        self.description
    }

    private static func sanitizedCompanionValues(
        _ values: [String: String],
        provider: WindowsProviderID) -> [String: String]
    {
        guard let schema = WindowsProviderConfigurationCatalog.byProvider[provider] else { return [:] }
        let permittedIDs = Set(
            schema.credentialSets.lazy.flatMap(\.fields).filter { !$0.secret }.map(\.id))
        return values.filter { permittedIDs.contains($0.key) }
    }
}

struct WindowsAppConfiguration: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    static let currentSchemaVersion = 8
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
        providers: [WindowsProviderConfiguration])
    {
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
        self.refreshIntervalMinutes = try Self.normalizedRefreshIntervalMinutes(
            container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
                ?? Self.defaultRefreshIntervalMinutes)
        self.runAtStartup = try container.decodeIfPresent(Bool.self, forKey: .runAtStartup) ?? false
        self.providers =
            try container.decodeIfPresent([WindowsProviderConfiguration].self, forKey: .providers) ?? []
        var seenProfiles = Set<WindowsProviderProfileID>()
        let reserved = Dictionary(uniqueKeysWithValues: WindowsProviderCatalog.entries.map {
            (WindowsProviderProfileID.defaultID(for: $0.id), $0.id)
        })
        guard self.providers.allSatisfy({ profile in
            seenProfiles.insert(profile.profileID).inserted
                && (reserved[profile.profileID] == nil || reserved[profile.profileID] == profile.id)
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .providers,
                in: container,
                debugDescription: "Duplicate or reserved provider profile ID")
        }
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
        var seenProviders = Set(self.providers.map(\.id))
        var nextOrder = (self.providers.map(\.order).max() ?? -1) + 1

        for entry in WindowsProviderCatalog.entries where seenProviders.insert(entry.id).inserted {
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

    var debugDescription: String {
        self.description
    }

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

    var enabledProfileIDs: [WindowsProviderProfileID] {
        self.enabledProviders.map(\.profileID)
    }

    func profileCount(for provider: WindowsProviderID) -> Int {
        self.providers.lazy.count(where: { $0.id == provider })
    }

    mutating func addProfile(for provider: WindowsProviderID) -> WindowsProviderConfiguration? {
        guard WindowsProviderCatalog.byID[provider] != nil,
              WindowsProviderConfigurationCatalog.unavailableInfo(for: provider) == nil
        else { return nil }
        let nextOrder = (self.providers.map(\.order).max() ?? -1) + 1
        let profile = WindowsProviderConfiguration(
            id: provider,
            profileID: .new(),
            profileName: self.uniqueProfileName(for: provider),
            enabled: true,
            order: nextOrder)
        self.providers.append(profile)
        self.providers = Self.sectionedProviders(self.providers)
        return profile
    }

    @discardableResult
    mutating func removeProfile(_ profileID: WindowsProviderProfileID) -> Bool {
        guard let profile = self.providers.first(where: { $0.profileID == profileID }),
              self.profileCount(for: profile.id) > 1
        else { return false }
        self.providers.removeAll { $0.profileID == profileID }
        self.providers = Self.sectionedProviders(self.providers)
        return true
    }

    @discardableResult
    mutating func setProviderEnabled(_ profileID: WindowsProviderProfileID, enabled: Bool) -> Bool {
        let ordered = self.orderedProviders
        guard var changed = ordered.first(where: { $0.profileID == profileID }), changed.enabled != enabled
        else {
            return false
        }

        var enabledProviders = ordered.filter { $0.enabled && $0.profileID != profileID }
        var disabledProviders = ordered.filter { !$0.enabled && $0.profileID != profileID }
        changed.enabled = enabled
        if enabled {
            enabledProviders.append(changed)
        } else {
            disabledProviders.insert(changed, at: 0)
        }
        self.providers = Self.assigningOrders(to: enabledProviders + disabledProviders)
        return true
    }

    @discardableResult
    mutating func setProviderEnabled(_ provider: WindowsProviderID, enabled: Bool) -> Bool {
        self.setProviderEnabled(.defaultID(for: provider), enabled: enabled)
    }

    static func parsedRefreshIntervalMinutes(_ text: String) -> Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              allowedRefreshIntervalMinutes.contains(minutes)
        else {
            return nil
        }
        return minutes
    }

    private static func normalizedRefreshIntervalMinutes(_ minutes: Int) -> Int {
        min(
            self.allowedRefreshIntervalMinutes.upperBound,
            max(self.allowedRefreshIntervalMinutes.lowerBound, minutes))
    }

    private func uniqueProfileName(for provider: WindowsProviderID) -> String {
        let existing = Set(self.providers.filter { $0.id == provider }.map { $0.profileName.lowercased() })
        for index in 2...999 {
            let candidate = "Profile \(index)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "Profile"
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
        _ providers: [WindowsProviderConfiguration]) -> [WindowsProviderConfiguration]
    {
        let ordered = providers.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.rawValue < $1.id.rawValue
        }
        return self.assigningOrders(
            to: ordered.filter(\.enabled)
                + ordered.filter { !$0.enabled }.sorted(by: WindowsProviderSettingsSearch.alphabeticalOrder))
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
