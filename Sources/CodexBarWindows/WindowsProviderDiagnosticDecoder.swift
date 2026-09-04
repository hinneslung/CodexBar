import Foundation

struct WindowsProviderDiagnosticDecodeResult: Sendable {
  let snapshot: WindowsProviderSnapshot
  let shouldRetry: Bool
}

enum WindowsProviderDiagnosticDecoder {
  private static let maximumWindows = 32
  private static let maximumFetchAttempts = 32
  private static let maximumProviderSpecificValues = 32
  private static let maximumDetailSections = 8
  private static let maximumDetailRows = 24
  private static let maximumChartPoints = 120
  private static let maximumTextScalars = 300
  private static let maximumWindowMinutes = 5_256_000
  private static let acceptedRawPercentRange = -1_000.0...100_000.0

  static func decode(
    data: Data,
    requestedProvider: WindowsProviderID,
    source: WindowsProviderSourcePresentation
  ) throws -> WindowsProviderSnapshot {
    try self.decodeResult(
      data: data,
      requestedProvider: requestedProvider,
      source: source
    ).snapshot
  }

  static func decodeResult(
    data: Data,
    requestedProvider: WindowsProviderID,
    source: WindowsProviderSourcePresentation
  ) throws -> WindowsProviderDiagnosticDecodeResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(Self.decodeDate)
    let payload: Payload
    do {
      payload = try decoder.decode(Payload.self, from: data)
    } catch {
      throw WindowsCanonicalCLIError.invalidPayload
    }

    guard payload.schemaVersion == "1.0" else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    guard payload.provider == requestedProvider.rawValue else {
      throw WindowsCanonicalCLIError.providerMismatch
    }
    try Self.validate(payload)

    if let error = payload.error, payload.usage == nil {
      return WindowsProviderDiagnosticDecodeResult(
        snapshot: WindowsProviderSnapshot(
          provider: requestedProvider,
          availability: .error,
          source: source,
          safeErrorText: Self.safeErrorMessage(category: error.category),
          updatedAt: payload.timestamp),
        shouldRetry: ["network", "api"].contains(error.category))
    }
    guard let usage = payload.usage else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    let resolvedSource = source.resolvingUpstream(payload.source, provider: requestedProvider)

    let windows = usage.windows.compactMap { window -> WindowsProviderWindowSnapshot? in
      guard window.usageKnown else { return nil }
      return WindowsProviderWindowSnapshot(
        label: Self.windowLabel(window),
        usedPercent: min(100, max(0, window.usedPercent)),
        resetText: Self.resetText(window),
        resetsAt: window.resetsAt)
    }
    let usageSummary = Self.usageSummary(usage)
    return WindowsProviderDiagnosticDecodeResult(
      snapshot: WindowsProviderSnapshot(
        provider: requestedProvider,
        availability: .available,
        usedPercent: windows.first?.usedPercent,
        usageSummaryText: usageSummary,
        resetText: windows.first?.resetText,
        source: resolvedSource,
        windows: windows,
        updatedAt: usage.updatedAt),
      shouldRetry: false)
  }

  private static func validate(_ payload: Payload) throws {
    guard (payload.usage == nil) != (payload.error == nil) else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    guard payload.sourceMode == "web", payload.settings.sourceMode == "web" else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    if payload.usage != nil, payload.source != "web" {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    _ = try Self.safeText(payload.displayName, required: true)
    _ = try Self.safeText(payload.platform, required: true)
    _ = try Self.safeText(payload.source, required: true)
    _ = try Self.safeText(payload.sourceMode, required: true)
    try Self.validateDate(payload.timestamp)
    guard payload.auth.modes.count <= 16,
      payload.fetchAttempts.count <= Self.maximumFetchAttempts
    else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    for mode in payload.auth.modes {
      _ = try Self.safeText(mode, required: true)
    }
    for attempt in payload.fetchAttempts {
      _ = try Self.safeText(attempt.kind, required: true)
      if let category = attempt.errorCategory {
        _ = try Self.safeText(category, required: true)
      }
    }
    _ = try Self.safeText(payload.settings.sourceMode, required: true)
    if let apiRegion = payload.settings.apiRegion {
      _ = try Self.safeText(apiRegion, required: true)
    }
    if let error = payload.error {
      _ = try Self.safeText(error.category, required: true)
      _ = try Self.safeText(error.safeDescription, required: true)
    }
    if let usage = payload.usage {
      try Self.validate(usage)
    }
  }

  private static func validate(_ usage: Usage) throws {
    try Self.validateDate(usage.updatedAt)
    guard ["exact", "estimated", "percentOnly", "unknown"].contains(usage.dataConfidence),
      usage.windows.count <= Self.maximumWindows,
      (0...Self.maximumWindows).contains(usage.extraWindowCount),
      usage.providerSpecificData.count <= Self.maximumProviderSpecificValues,
      usage.detailSections.count <= Self.maximumDetailSections
    else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    for value in usage.providerSpecificData {
      _ = try Self.safeText(value, required: true)
    }
    for window in usage.windows {
      _ = try Self.safeText(window.label, required: true)
      guard window.usedPercent.isFinite,
        Self.acceptedRawPercentRange.contains(window.usedPercent)
      else {
        throw WindowsCanonicalCLIError.invalidPayload
      }
      if let minutes = window.windowMinutes,
        !(1...Self.maximumWindowMinutes).contains(minutes)
      {
        throw WindowsCanonicalCLIError.invalidPayload
      }
      if let nextRegenPercent = window.nextRegenPercent,
        !nextRegenPercent.isFinite || !Self.acceptedRawPercentRange.contains(nextRegenPercent)
      {
        throw WindowsCanonicalCLIError.invalidPayload
      }
      if let resetsAt = window.resetsAt {
        try Self.validateDate(resetsAt)
      }
    }
    for section in usage.detailSections {
      if let title = section.title {
        _ = try Self.safeText(title, required: false)
      }
      guard section.rows.count <= Self.maximumDetailRows else {
        throw WindowsCanonicalCLIError.invalidPayload
      }
      for row in section.rows {
        _ = try Self.safeText(row.label, required: true)
        _ = try Self.safeText(row.value, required: true)
        if let secondary = row.secondaryValue {
          _ = try Self.safeText(secondary, required: false)
        }
      }
      if let chart = section.chart {
        guard ["bars", "line"].contains(chart.kind),
          chart.points.count <= Self.maximumChartPoints
        else {
          throw WindowsCanonicalCLIError.invalidPayload
        }
        if let title = chart.title { _ = try Self.safeText(title, required: false) }
        if let unit = chart.unit { _ = try Self.safeText(unit, required: false) }
        for point in chart.points {
          _ = try Self.safeText(point.label, required: true)
          guard point.value.isFinite, abs(point.value) <= 1_000_000_000_000_000 else {
            throw WindowsCanonicalCLIError.invalidPayload
          }
        }
      }
    }
  }

  private static func windowLabel(_ window: RateWindow) -> String {
    let label = (try? Self.safeText(window.label, required: true)) ?? "Usage"
    switch label.lowercased() {
    case "primary": return "Session"
    case "secondary": return "Weekly"
    case "tertiary": return "Monthly"
    default: return label
    }
  }

  private static func resetText(_ window: RateWindow) -> String? {
    if let label = WindowsResetLabelFormatter.label(resetsAt: window.resetsAt, description: nil) {
      return label
    }
    guard window.hasResetDescription, let minutes = window.windowMinutes else { return nil }
    if minutes == 10_080 { return "Weekly" }
    if (40_000...50_000).contains(minutes) { return "Monthly" }
    if minutes.isMultiple(of: 1_440) {
      let days = minutes / 1_440
      return "\(days)-day window"
    }
    if minutes.isMultiple(of: 60) {
      let hours = minutes / 60
      return "\(hours)-hour window"
    }
    return "\(minutes)-minute window"
  }

  private static func usageSummary(_ usage: Usage) -> String? {
    var values: [String] = []
    switch usage.dataConfidence {
    case "estimated": values.append("Estimated usage")
    case "percentOnly": values.append("Percentage-only usage")
    case "unknown": values.append("Usage confidence unknown")
    default: break
    }
    let result = values.joined(separator: " · ")
    return result.isEmpty ? nil : String(result.prefix(300))
  }

  private static func safeText(_ rawValue: String, required: Bool) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !required || !value.isEmpty, value.unicodeScalars.count <= Self.maximumTextScalars,
      !value.unicodeScalars.contains(where: {
        ($0.properties.generalCategory == .control && !$0.properties.isWhitespace)
          || $0.properties.generalCategory == .format
      })
    else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
    return value
  }

  private static func validateDate(_ date: Date) throws {
    let year = Calendar(identifier: .gregorian).component(.year, from: date)
    guard (2000...2200).contains(year) else {
      throw WindowsCanonicalCLIError.invalidPayload
    }
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

  private static func safeErrorMessage(category: String) -> String {
    switch category {
    case "network": "The provider could not be reached. Check your connection."
    case "auth": "Provider authentication or setup needs attention."
    case "api": "The provider returned an unexpected response."
    case "parse": "The provider response could not be understood."
    case "configuration": "Check this provider's credential settings."
    default: "Provider usage is unavailable."
    }
  }

  private struct Payload: Decodable {
    let schemaVersion: String
    let timestamp: Date
    let platform: String
    let provider: String
    let displayName: String
    let source: String
    let sourceMode: String
    let auth: Auth
    let usage: Usage?
    let fetchAttempts: [FetchAttempt]
    let error: DiagnosticError?
    let settings: Settings
    let details: NullOnly?
  }

  private struct Auth: Decodable {
    let configured: Bool
    let modes: [String]
  }

  private struct Usage: Decodable {
    let updatedAt: Date
    let dataConfidence: String
    let windows: [RateWindow]
    let extraWindowCount: Int
    let providerCostPresent: Bool
    let providerSpecificData: [String]
    let detailSections: [DetailSection]
  }

  private struct RateWindow: Decodable {
    let label: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let hasResetDescription: Bool
    let nextRegenPercent: Double?
    let usageKnown: Bool

    private enum CodingKeys: String, CodingKey {
      case label
      case usedPercent
      case windowMinutes
      case resetsAt
      case hasResetDescription
      case nextRegenPercent
      case usageKnown
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.label = try container.decode(String.self, forKey: .label)
      self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
      self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
      self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
      self.hasResetDescription = try container.decode(Bool.self, forKey: .hasResetDescription)
      self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
      self.usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true
    }
  }

  private struct FetchAttempt: Decodable {
    let kind: String
    let wasAvailable: Bool
    let errorCategory: String?
  }

  private struct DiagnosticError: Decodable {
    let category: String
    let safeDescription: String
  }

  private struct Settings: Decodable {
    let sourceMode: String
    let apiRegion: String?
  }

  private struct DetailSection: Decodable {
    let title: String?
    let rows: [DetailRow]
    let chart: DetailChart?
  }

  private struct DetailRow: Decodable {
    let label: String
    let value: String
    let secondaryValue: String?
  }

  private struct DetailChart: Decodable {
    let kind: String
    let title: String?
    let unit: String?
    let points: [DetailPoint]
  }

  private struct DetailPoint: Decodable {
    let label: String
    let value: Double
  }

  private struct NullOnly: Decodable {
    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      guard container.decodeNil() else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Provider-specific diagnostic details are unsupported")
      }
    }
  }
}
