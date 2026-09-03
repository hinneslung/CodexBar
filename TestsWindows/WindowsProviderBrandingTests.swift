#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  struct WindowsProviderBrandingTests {
    @Test
    func `every catalog provider maps to a unique atlas cell backed by an upstream logo`() {
      let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let upstreamResources =
        repositoryRoot
        .appendingPathComponent("Sources/CodexBar/Resources", isDirectory: true)

      for (index, entry) in WindowsProviderCatalog.entries.enumerated() {
        let reference = WindowsProviderBranding.logo(for: entry.id)
        #expect(reference.atlasIndex == index)
        #expect(!reference.usesFallback)
        #expect(
          FileManager.default.fileExists(
            atPath:
              upstreamResources
              .appendingPathComponent("\(reference.upstreamResourceName).svg")
              .path),
          "Missing upstream logo for \(entry.id)")
      }
    }

    @Test
    func `descriptor aliases reuse their upstream artwork`() {
      #expect(
        WindowsProviderBranding.logo(for: .openai).upstreamResourceName == "ProviderIcon-codex")
      #expect(
        WindowsProviderBranding.logo(for: .azureOpenAI).upstreamResourceName
          == "ProviderIcon-codex")
      #expect(
        WindowsProviderBranding.logo(for: .alibabaTokenPlan).upstreamResourceName
          == "ProviderIcon-alibaba")
      #expect(
        WindowsProviderBranding.logo(for: .moonshot).upstreamResourceName == "ProviderIcon-kimi")
    }

    @Test
    func `unknown providers map to the final fallback cell`() {
      let reference = WindowsProviderBranding.logo(for: WindowsProviderID("future-provider"))
      #expect(reference.atlasIndex == WindowsProviderCatalog.entries.count)
      #expect(reference.usesFallback)
    }

    @Test
    func `bundled atlas loads as a GDI bitmap`() {
      #expect(WindowsProviderLogoAtlas.load() != nil)
    }
  }
#endif
