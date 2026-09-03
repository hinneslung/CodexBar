import Foundation

/// Offline QA data source. Its short delay keeps the loading state observable without contacting providers.
struct WindowsUnavailableProviderAdapter: WindowsProviderDataSource {
  func fetchProviderSnapshots() async -> [WindowsProviderSnapshot] {
    try? await Task.sleep(for: .milliseconds(1500))
    return WindowsProviderID.liveProviders.map { provider in
      WindowsProviderSnapshot(
        provider: provider,
        availability: .unavailable,
        sourceText: "Windows adapter stub",
        safeErrorText: "Provider coordinator not connected")
    }
  }
}
