import Foundation

protocol WindowsProviderDataSource: Sendable {
  func fetchProviderSnapshots() async -> [WindowsProviderSnapshot]
}
struct AnyWindowsProviderDataSource: WindowsProviderDataSource, Sendable {
  private let fetch: @Sendable () async -> [WindowsProviderSnapshot]

  init(fetch: @escaping @Sendable () async -> [WindowsProviderSnapshot]) {
    self.fetch = fetch
  }

  init(_ dataSource: some WindowsProviderDataSource) {
    self.fetch = {
      await dataSource.fetchProviderSnapshots()
    }
  }

  func fetchProviderSnapshots() async -> [WindowsProviderSnapshot] {
    await self.fetch()
  }
}
