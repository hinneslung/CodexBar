#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows canonical CLI discovery cache")
  struct WindowsCanonicalCLIDiscoveryCacheTests {
    @Test("concurrent provider refreshes share one WSL discovery probe")
    func coalescesConcurrentDiscovery() async {
      let counter = ProbeCounter()
      let cache = WindowsCanonicalCLIDiscoveryCache(
        positiveLifetime: 60,
        negativeLifetime: 1,
        resolver: { _, _ in await counter.resolve() })

      let first = Task {
        await cache.executablePath(distribution: "Ubuntu", windowsDirectory: "C:\\Windows")
      }
      let second = Task {
        await cache.executablePath(distribution: "ubuntu", windowsDirectory: "c:\\windows")
      }

      #expect(await first.value == "/usr/bin/codexbar")
      #expect(await second.value == "/usr/bin/codexbar")
      #expect(await counter.value == 1)
      #expect(
        await cache.executablePath(distribution: "Ubuntu", windowsDirectory: "C:\\Windows")
          == "/usr/bin/codexbar")
      #expect(await counter.value == 1)
    }

    private actor ProbeCounter {
      private(set) var value = 0

      func resolve() async -> String? {
        self.value += 1
        try? await Task.sleep(for: .milliseconds(30))
        return "/usr/bin/codexbar"
      }
    }
  }
#endif
