#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows WSL source discovery")
  struct WindowsWSLSourceDiscoveryTests {
    @Test("default user home resolves only the registry selected non-root UID")
    func resolvesSelectedDefaultUser() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-wsl-home-\(UUID().uuidString)", isDirectory: true)
      let etc = root.appendingPathComponent("etc", isDirectory: true)
      try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data(
        "root:x:0:0:root:/root:/bin/bash\nselected:x:1000:1000::/home/selected:/bin/bash\n"
          .utf8
      ).write(to: etc.appendingPathComponent("passwd"))

      let home = WindowsWSLDefaultUserHome.directory(distributionRoot: root, defaultUID: 1000)
      #expect(home?.lastPathComponent == "selected")
      #expect(WindowsWSLDefaultUserHome.directory(distributionRoot: root, defaultUID: 0) == nil)
      #expect(WindowsWSLDefaultUserHome.directory(distributionRoot: root, defaultUID: 1001) == nil)
    }

    @Test("distribution names cannot escape the WSL localhost root")
    func validatesDistributionNames() {
      #expect(WindowsWSLDistributionRegistry.isSafeDistributionName("Ubuntu-24.04"))
      #expect(!WindowsWSLDistributionRegistry.isSafeDistributionName("../Ubuntu"))
      #expect(!WindowsWSLDistributionRegistry.isSafeDistributionName("Ubuntu\\other"))
      #expect(!WindowsWSLDistributionRegistry.isSafeDistributionName("\n"))
    }
  }
#endif
