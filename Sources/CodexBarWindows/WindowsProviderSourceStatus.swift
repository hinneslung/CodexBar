import Foundation

enum WindowsProviderSourceStatus {
  static func errorText(row: WindowsProviderRowPresentation?) -> String? {
    guard let row, row.statusText != "Loading", row.statusText != "Available" else { return nil }
    return row.errorText.isEmpty ? "Usage could not be loaded from this source." : row.errorText
  }
}

enum WindowsProviderConfigurationPageState {
  static func hasUnsavedChanges(
    draft: WindowsProviderConfiguration,
    saved: WindowsProviderConfiguration
  ) -> Bool {
    self.sourceKey(draft) != self.sourceKey(saved)
  }

  static func errorText(
    provider: WindowsProviderID,
    lastAppliedProvider: WindowsProviderID?,
    draft: WindowsProviderConfiguration,
    saved: WindowsProviderConfiguration,
    isRefreshing: Bool,
    row: WindowsProviderRowPresentation?
  ) -> String? {
    guard lastAppliedProvider == provider,
      !self.hasUnsavedChanges(draft: draft, saved: saved),
      !isRefreshing
    else { return nil }
    return WindowsProviderSourceStatus.errorText(row: row)
  }

  private static func sourceKey(_ configuration: WindowsProviderConfiguration) -> String {
    guard configuration.sourceMode == .wsl,
      let distribution = configuration.wslDistro?.trimmingCharacters(in: .whitespacesAndNewlines),
      !distribution.isEmpty
    else { return "automatic" }
    return "wsl:\(distribution.lowercased())"
  }
}
