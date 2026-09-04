#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows configured provider live checks")
  struct WindowsConfiguredProviderLiveTests {
    @Test("configured providers resolve through the canonical CLI runtime")
    func resolvesConfiguredProviders() async throws {
      guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_PROVIDER_TESTS"] == "1" else {
        return
      }
      let store = try WindowsConfigurationStore()
      let enabled = try store.load().providers.filter(\.enabled).map(\.id)
      let snapshots = await WindowsConfiguredProviderDataSource(store: store)
        .fetchProviderSnapshots()
      let byProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

      #expect(Set(byProvider.keys) == Set(enabled))
      for provider in enabled {
        let snapshot = try #require(byProvider[provider])
        let failure = snapshot.safeErrorText ?? "unavailable"
        #expect(
          snapshot.availability == .available,
          "\(provider.displayName): \(failure)")
      }
    }
  }
#endif
