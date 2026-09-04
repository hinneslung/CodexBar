import Foundation

enum WindowsProviderAvailability: String, Codable, Sendable {
  case loading
  case available
  case unavailable
  case error
}

struct WindowsProviderWindowSnapshot: Equatable, Sendable {
  let label: String
  let usedPercent: Double
  let resetText: String?
  let resetsAt: Date?

  init(label: String, usedPercent: Double, resetText: String? = nil, resetsAt: Date? = nil) {
    self.label = label
    self.usedPercent = usedPercent
    self.resetText = resetText
    self.resetsAt = resetsAt
  }
}

/// Display-safe provider data. Adapters must never place credentials, cookies, or raw response bodies in these fields.
struct WindowsProviderSnapshot: Sendable {
  let provider: WindowsProviderID
  let availability: WindowsProviderAvailability
  let usedPercent: Double?
  let usageSummaryText: String?
  let resetText: String?
  let source: WindowsProviderSourcePresentation
  let safeErrorText: String?
  let windows: [WindowsProviderWindowSnapshot]
  let planText: String?
  let balanceText: String?
  let accountText: String?
  let updatedAt: Date?
  /// Internal coordination marker. A stale/cancelled fetch must be retried, never published or cached.
  let discardsRefreshResult: Bool
  /// Revalidates the credential revision at the final presentation boundary.
  /// The publisher invokes this only while holding this provider's operation mutex.
  let publicationAuthorityCheck: (@Sendable () throws -> Bool)?

  init(
    provider: WindowsProviderID,
    availability: WindowsProviderAvailability,
    usedPercent: Double? = nil,
    usageSummaryText: String? = nil,
    resetText: String? = nil,
    source: WindowsProviderSourcePresentation,
    safeErrorText: String? = nil,
    windows: [WindowsProviderWindowSnapshot] = [],
    planText: String? = nil,
    balanceText: String? = nil,
    accountText: String? = nil,
    updatedAt: Date? = nil,
    discardsRefreshResult: Bool = false,
    publicationAuthorityCheck: (@Sendable () throws -> Bool)? = nil
  ) {
    self.provider = provider
    self.availability = availability
    self.usedPercent = usedPercent
    self.usageSummaryText = usageSummaryText
    self.resetText = resetText
    self.source = source
    self.safeErrorText = safeErrorText
    self.windows = windows
    self.planText = planText
    self.balanceText = balanceText
    self.accountText = accountText
    self.updatedAt = updatedAt
    self.discardsRefreshResult = discardsRefreshResult
    self.publicationAuthorityCheck = publicationAuthorityCheck
  }

  func replacingSource(_ source: WindowsProviderSourcePresentation) -> Self {
    Self(
      provider: self.provider,
      availability: self.availability,
      usedPercent: self.usedPercent,
      usageSummaryText: self.usageSummaryText,
      resetText: self.resetText,
      source: source,
      safeErrorText: self.safeErrorText,
      windows: self.windows,
      planText: self.planText,
      balanceText: self.balanceText,
      accountText: self.accountText,
      updatedAt: self.updatedAt,
      discardsRefreshResult: self.discardsRefreshResult,
      publicationAuthorityCheck: self.publicationAuthorityCheck)
  }

  init(
    provider: WindowsProviderID,
    availability: WindowsProviderAvailability,
    usedPercent: Double? = nil,
    usageSummaryText: String? = nil,
    resetText: String? = nil,
    sourceText: String,
    safeErrorText: String? = nil,
    windows: [WindowsProviderWindowSnapshot] = [],
    planText: String? = nil,
    balanceText: String? = nil,
    accountText: String? = nil,
    updatedAt: Date? = nil,
    discardsRefreshResult: Bool = false,
    publicationAuthorityCheck: (@Sendable () throws -> Bool)? = nil
  ) {
    self.init(
      provider: provider,
      availability: availability,
      usedPercent: usedPercent,
      usageSummaryText: usageSummaryText,
      resetText: resetText,
      source: .compatibility(sourceText),
      safeErrorText: safeErrorText,
      windows: windows,
      planText: planText,
      balanceText: balanceText,
      accountText: accountText,
      updatedAt: updatedAt,
      discardsRefreshResult: discardsRefreshResult,
      publicationAuthorityCheck: publicationAuthorityCheck)
  }

  var sourceText: String { self.source.formattedValue }

  func requiringPublicationAuthority(
    _ check: (@Sendable () throws -> Bool)?
  ) -> Self {
    Self(
      provider: self.provider,
      availability: self.availability,
      usedPercent: self.usedPercent,
      usageSummaryText: self.usageSummaryText,
      resetText: self.resetText,
      source: self.source,
      safeErrorText: self.safeErrorText,
      windows: self.windows,
      planText: self.planText,
      balanceText: self.balanceText,
      accountText: self.accountText,
      updatedAt: self.updatedAt,
      discardsRefreshResult: self.discardsRefreshResult,
      publicationAuthorityCheck: check)
  }
}

struct WindowsUsageWindowPresentation: Equatable, Sendable {
  let label: String
  let usedPercent: Double
  let percentText: String
  let resetText: String
  let resetsAt: Date?

  init(
    label: String,
    usedPercent: Double,
    percentText: String,
    resetText: String,
    resetsAt: Date? = nil
  ) {
    self.label = label
    self.usedPercent = usedPercent
    self.percentText = percentText
    self.resetText = resetText
    self.resetsAt = resetsAt
  }

  func displayedPercent(showUsed: Bool) -> Double {
    showUsed ? self.usedPercent : 100 - self.usedPercent
  }

  func displayedPercentText(showUsed: Bool) -> String {
    String(
      format: "%.0f%% %@", self.displayedPercent(showUsed: showUsed), showUsed ? "used" : "left")
  }

  var overviewResetText: String {
    let normalized = self.resetText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.caseInsensitiveCompare("Reset unavailable") != .orderedSame
    else {
      return ""
    }
    return normalized
  }
}

struct WindowsProviderRowPresentation: Equatable, Sendable {
  let provider: WindowsProviderID
  let statusText: String
  let percentText: String
  let resetText: String
  let sourceText: String
  let errorText: String
  let windows: [WindowsUsageWindowPresentation]
  let planText: String
  let balanceText: String
  let accountText: String
  let measuredText: String

  var governingWindow: WindowsUsageWindowPresentation? {
    self.windows.max(by: { $0.usedPercent < $1.usedPercent })
  }

  var dashboardText: String {
    let details = [self.percentText, self.resetText, "Source: \(self.sourceText)", self.errorText]
      .filter { !$0.isEmpty }
      .joined(separator: "  •  ")
    return "\(self.provider.displayName) — \(self.statusText)\r\n\(details)"
  }

  var accessibilityText: String {
    [
      self.provider.displayName,
      self.statusText,
      self.percentText,
      self.resetText,
      self.planText,
      self.balanceText,
      self.accountText,
      self.measuredText,
      self.sourceText,
      self.errorText,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: ". ")
  }

  var overviewStatusText: String {
    if !self.errorText.isEmpty {
      return self.errorText
    }
    let plan = self.planText.replacingOccurrences(of: "Plan: ", with: "")
    let balance =
      self.governingWindow == nil
      ? ""
      : (WindowsProviderBalanceFormatter.compact(self.balanceText) ?? self.balanceText)
    let context = [plan, balance]
      .filter { !$0.isEmpty }
      .joined(separator: "  •  ")
    if !context.isEmpty { return context }
    return self.statusText == "Available" ? "" : self.statusText
  }
}

enum WindowsProviderBalanceFormatter {
  static func compact(_ value: String) -> String? {
    let hasRemainingSuffix =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .hasSuffix(" remaining")
    let normalized =
      value
      .replacingOccurrences(of: " remaining", with: "")
      .replacingOccurrences(of: " credits used", with: " used")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let components = normalized.split(separator: " ", maxSplits: 1).map(String.init)
    guard let raw = components.first,
      let amount = Double(raw.replacingOccurrences(of: ",", with: ""))
    else { return normalized }
    let number: String
    if amount >= 1_000_000 {
      number = String(format: "%.1fM", amount / 1_000_000).replacingOccurrences(
        of: ".0M", with: "M")
    } else if amount >= 1_000 {
      number = String(format: "%.1fk", amount / 1_000).replacingOccurrences(of: ".0k", with: "k")
    } else {
      number = raw
    }

    guard components.count > 1 else { return number }
    let unit = components[1].lowercased().hasPrefix("point") ? "pts" : components[1]
    return "\(number) \(unit)\(hasRemainingSuffix ? " left" : "")"
  }
}

enum WindowsResetLabelFormatter {
  static func label(
    resetsAt: Date?,
    description: String?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> String? {
    if let resetsAt {
      let seconds = Int(resetsAt.timeIntervalSince(now).rounded(.down))
      if seconds <= 0 { return "Pending" }
      if seconds < 86_400 { return self.duration(seconds) }
      if seconds < 7 * 86_400 {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: resetsAt)
      }
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = "MMM d, HH:mm"
      return formatter.string(from: resetsAt)
    }
    return self.normalizedDescription(description)
  }

  static func compact(resetsAt: Date?, description: String?, now: Date = Date()) -> String? {
    if let resetsAt {
      let seconds = Int(resetsAt.timeIntervalSince(now).rounded(.down))
      if seconds <= 0 { return "pending" }
      if seconds < 60 { return "<1m" }
      if seconds < 3600 { return "\(seconds / 60)m" }
      if seconds < 86_400 { return "\(seconds / 3600)h" }
      return "\(seconds / 86_400)d"
    }
    guard let normalized = self.normalizedDescription(description) else { return nil }
    let words = normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard let first = words.first else { return nil }
    if let token = self.compactDurationToken(first, unit: words.dropFirst().first) { return token }
    if first.caseInsensitiveCompare("pending") == .orderedSame { return "pending" }
    if first.caseInsensitiveCompare("tomorrow") == .orderedSame { return "tomorrow" }
    return String(normalized.lowercased().prefix(12))
  }

  private static func normalizedDescription(_ value: String?) -> String? {
    guard let value else { return nil }
    var normalized =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !normalized.isEmpty,
      normalized.caseInsensitiveCompare("Reset unavailable") != .orderedSame
    else { return nil }
    for prefix in ["Resets in ", "Reset in ", "Resets at ", "Reset at ", "Resets ", "Reset "]
    where normalized.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
      normalized.removeFirst(prefix.count)
      break
    }
    normalized = normalized.replacingOccurrences(
      of: #"\s*\((?:UTC|GMT)[^)]*\)\s*$"#,
      with: "",
      options: [.regularExpression, .caseInsensitive])
    normalized = normalized.replacingOccurrences(
      of: #"\s+(?:UTC|GMT)(?:[+-]\d{1,2}(?::?\d{2})?)?\s*$"#,
      with: "",
      options: [.regularExpression, .caseInsensitive])
    let words = normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
    if let first = words.first,
      let compact = self.compactDurationToken(first, unit: words.dropFirst().first)
    {
      if words.count <= 2 { return compact }
      return ([compact] + words.dropFirst(2)).joined(separator: " ")
    }
    return normalized.isEmpty ? nil : normalized
  }

  private static func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "<1m" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }

  private static func compactDurationToken(_ value: String, unit: String?) -> String? {
    let token = value.lowercased()
    if token == "<1m" { return token }
    if let suffix = token.last, ["m", "h", "d", "w"].contains(suffix),
      token.dropLast().allSatisfy(\.isNumber)
    {
      return token
    }
    guard token.allSatisfy(\.isNumber), let unit else { return nil }
    let suffix =
      switch unit.lowercased() {
      case "minute", "minutes": "m"
      case "hour", "hours": "h"
      case "day", "days": "d"
      case "week", "weeks": "w"
      default: ""
      }
    return suffix.isEmpty ? nil : "\(token)\(suffix)"
  }
}

struct WindowsDashboardPresentation: Equatable, Sendable {
  private static let trayTooltipUTF16Limit = 127

  let rows: [WindowsProviderRowPresentation]
  let refreshedAt: Date?
  let isRefreshing: Bool

  static func loading(
    providers: [WindowsProviderID] = WindowsProviderID.initiallyEnabledProviders
  ) -> Self {
    Self(
      rows: providers.map { provider in
        WindowsProviderRowPresentation(
          provider: provider,
          statusText: "Loading",
          percentText: "Usage unavailable",
          resetText: "Reset unavailable",
          sourceText: "Source unavailable",
          errorText: "",
          windows: [],
          planText: "",
          balanceText: "",
          accountText: "",
          measuredText: "")
      },
      refreshedAt: nil,
      isRefreshing: true)
  }

  static func make(
    snapshots: [WindowsProviderSnapshot],
    refreshedAt: Date,
    providers: [WindowsProviderID] = WindowsProviderID.initiallyEnabledProviders,
    isRefreshing: Bool = false
  ) -> Self {
    let snapshotsByProvider = Dictionary(
      snapshots.map { ($0.provider, $0) }, uniquingKeysWith: { _, rhs in rhs })
    let rows = providers.map { provider in
      Self.makeRow(snapshot: snapshotsByProvider[provider], provider: provider)
    }
    return Self(rows: rows, refreshedAt: refreshedAt, isRefreshing: isRefreshing)
  }

  func trayTooltip(showUsed: Bool, now: Date = Date()) -> String {
    let lines = self.rows.map { Self.trayTooltipLine(for: $0, showUsed: showUsed, now: now) }
    guard !lines.isEmpty else { return "CodexBar" }
    return Self.boundedTrayTooltip(lines)
  }

  private static func trayTooltipLine(
    for row: WindowsProviderRowPresentation,
    showUsed: Bool,
    now: Date
  ) -> String {
    if let governing = row.governingWindow {
      let percent = String(format: "%.0f%%", governing.displayedPercent(showUsed: showUsed))
      let detail = Self.compactReset(for: governing, now: now).map { " \($0)" } ?? ""
      return "\(row.provider.displayName) - \(percent)\(detail)"
    }
    if let balance = WindowsProviderBalanceFormatter.compact(row.balanceText), !balance.isEmpty {
      return "\(row.provider.displayName) - \(balance)"
    }
    return "\(row.provider.displayName) - \(row.statusText.lowercased())"
  }

  private static func boundedTrayTooltip(_ lines: [String]) -> String {
    var visibleLines: [String] = []
    for line in lines {
      let candidate = (visibleLines + [line]).joined(separator: "\n")
      guard candidate.utf16.count <= Self.trayTooltipUTF16Limit else { break }
      visibleLines.append(line)
    }

    var omittedCount = lines.count - visibleLines.count
    guard omittedCount > 0 else { return visibleLines.joined(separator: "\n") }
    var omission = "+\(omittedCount) more"
    while !visibleLines.isEmpty,
      (visibleLines + [omission]).joined(separator: "\n").utf16.count
        > Self.trayTooltipUTF16Limit
    {
      visibleLines.removeLast()
      omittedCount += 1
      omission = "+\(omittedCount) more"
    }
    if omission.utf16.count <= Self.trayTooltipUTF16Limit {
      visibleLines.append(omission)
    }
    return visibleLines.joined(separator: "\n")
  }

  private static func compactReset(
    for window: WindowsUsageWindowPresentation,
    now: Date
  ) -> String? {
    WindowsResetLabelFormatter.compact(
      resetsAt: window.resetsAt,
      description: window.resetText,
      now: now)
  }

  private static func makeRow(
    snapshot: WindowsProviderSnapshot?,
    provider: WindowsProviderID
  ) -> WindowsProviderRowPresentation {
    guard let snapshot else {
      return WindowsProviderRowPresentation(
        provider: provider,
        statusText: "Unavailable",
        percentText: "Usage unavailable",
        resetText: "Reset unavailable",
        sourceText: "Source unavailable",
        errorText: "No provider result",
        windows: [],
        planText: "",
        balanceText: "",
        accountText: "",
        measuredText: "")
    }

    let statusText =
      switch snapshot.availability {
      case .loading: "Loading"
      case .available: "Available"
      case .unavailable: "Unavailable"
      case .error: "Error"
      }
    let hasStructuredWindows = !snapshot.windows.isEmpty
    var windows = snapshot.windows.map { window in
      let percent = Self.normalizedPercent(window.usedPercent) ?? 0
      return WindowsUsageWindowPresentation(
        label: Self.displayText(window.label, fallback: "Usage"),
        usedPercent: percent,
        percentText: String(format: "%.0f%% used", percent),
        resetText: Self.displayText(
          WindowsResetLabelFormatter.label(
            resetsAt: window.resetsAt,
            description: window.resetText),
          fallback: "Reset unavailable"),
        resetsAt: window.resetsAt)
    }
    if windows.isEmpty, let usedPercent = Self.normalizedPercent(snapshot.usedPercent) {
      windows = [
        WindowsUsageWindowPresentation(
          label: "Usage",
          usedPercent: usedPercent,
          percentText: String(format: "%.0f%% used", usedPercent),
          resetText: Self.displayText(snapshot.resetText, fallback: "Reset unavailable"))
      ]
    }
    let percentText: String =
      if let summary = Self.displayText(snapshot.usageSummaryText) {
        summary
      } else if !hasStructuredWindows,
        let usedPercent = Self.normalizedPercent(snapshot.usedPercent)
      {
        String(format: "%.0f%% used", usedPercent)
      } else if !windows.isEmpty {
        windows.map { "\($0.label): \($0.percentText)" }.joined(separator: "; ")
      } else {
        "Usage unavailable"
      }
    let resetText = Self.displayText(
      snapshot.resetText ?? windows.first?.resetText,
      fallback: "Reset unavailable")
    return WindowsProviderRowPresentation(
      provider: provider,
      statusText: statusText,
      percentText: percentText,
      resetText: resetText,
      sourceText: snapshot.source.formattedValue,
      errorText: Self.displayText(snapshot.safeErrorText, fallback: ""),
      windows: windows,
      planText: Self.displayText(snapshot.planText, fallback: ""),
      balanceText: Self.displayText(snapshot.balanceText, fallback: ""),
      accountText: Self.displayText(snapshot.accountText, fallback: ""),
      measuredText: snapshot.updatedAt.map {
        "Measured \(ISO8601DateFormatter().string(from: $0))"
      } ?? "")
  }

  private static func normalizedPercent(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return min(100, max(0, value))
  }

  private static func displayText(_ value: String?, fallback: String) -> String {
    guard let value else { return fallback }
    let normalized =
      value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !normalized.isEmpty else { return fallback }
    return String(normalized.prefix(300))
  }

  private static func displayText(_ value: String?) -> String? {
    let normalized = Self.displayText(value, fallback: "")
    return normalized.isEmpty ? nil : normalized
  }
}
