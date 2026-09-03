import Foundation
import WinSDK

struct WindowsProviderLogoReference: Equatable, Sendable {
  let provider: WindowsProviderID
  let upstreamResourceName: String
  let atlasIndex: Int
  let usesFallback: Bool
}

enum WindowsProviderBranding {
  static let atlasCellSize: Int32 = 20
  static let atlasResourceName = "ProviderLogos"
  static let atlasResourceExtension = "bmp"

  /// Matches the intentional resource sharing in the upstream provider descriptors.
  private static let sharedResourceNames: [WindowsProviderID: String] = [
    .openai: "ProviderIcon-codex",
    .azureOpenAI: "ProviderIcon-codex",
    .alibabaTokenPlan: "ProviderIcon-alibaba",
    .moonshot: "ProviderIcon-kimi",
  ]

  private static let atlasIndices: [WindowsProviderID: Int] =
    Dictionary(
      uniqueKeysWithValues: WindowsProviderCatalog.entries.enumerated().map {
        ($0.element.id, $0.offset)
      })

  static func logo(for provider: WindowsProviderID) -> WindowsProviderLogoReference {
    guard let index = Self.atlasIndices[provider] else {
      return WindowsProviderLogoReference(
        provider: provider,
        upstreamResourceName: "ProviderIcon-fallback",
        atlasIndex: WindowsProviderCatalog.entries.count,
        usesFallback: true)
    }
    return WindowsProviderLogoReference(
      provider: provider,
      upstreamResourceName: Self.sharedResourceNames[provider]
        ?? "ProviderIcon-\(provider.rawValue)",
      atlasIndex: index,
      usesFallback: false)
  }
}

/// Owns the single pre-rasterized GDI bitmap shared by every provider row and header.
///
/// Cells follow `WindowsProviderCatalog.entries`; the final cell is a safe fallback for
/// forward-compatible provider IDs. The atlas is generated from upstream provider SVGs.
final class WindowsProviderLogoAtlas {
  private let bitmap: HBITMAP
  private let sourceDC: HDC
  private let previousBitmap: HGDIOBJ?

  private init(bitmap: HBITMAP, sourceDC: HDC, previousBitmap: HGDIOBJ?) {
    self.bitmap = bitmap
    self.sourceDC = sourceDC
    self.previousBitmap = previousBitmap
  }

  deinit {
    if let previousBitmap = self.previousBitmap {
      _ = SelectObject(self.sourceDC, previousBitmap)
    }
    _ = DeleteDC(self.sourceDC)
    _ = DeleteObject(self.bitmap)
  }

  static func load(bundle: Bundle = .module) -> WindowsProviderLogoAtlas? {
    guard
      let url = bundle.url(
        forResource: WindowsProviderBranding.atlasResourceName,
        withExtension: WindowsProviderBranding.atlasResourceExtension)
    else { return nil }
    return WindowsWideString.withPointer(url.path) { path in
      guard
        let handle = LoadImageW(
          nil,
          path,
          UINT(IMAGE_BITMAP),
          0,
          0,
          UINT(LR_LOADFROMFILE | LR_CREATEDIBSECTION)),
        let sourceDC = CreateCompatibleDC(nil)
      else { return nil }
      let bitmap = handle.assumingMemoryBound(to: HBITMAP__.self)
      let previousBitmap = SelectObject(sourceDC, bitmap)
      return WindowsProviderLogoAtlas(
        bitmap: bitmap,
        sourceDC: sourceDC,
        previousBitmap: previousBitmap)
    }
  }

  @discardableResult
  func draw(provider: WindowsProviderID, dc: HDC?, rect: RECT) -> Bool {
    guard let dc else { return false }
    let width = rect.right - rect.left
    let height = rect.bottom - rect.top
    guard width > 0, height > 0 else { return false }

    let reference = WindowsProviderBranding.logo(for: provider)
    let previousMode = SetStretchBltMode(dc, Int32(HALFTONE))
    defer {
      if previousMode != 0 { _ = SetStretchBltMode(dc, previousMode) }
    }
    _ = SetBrushOrgEx(dc, rect.left, rect.top, nil)
    return StretchBlt(
      dc,
      rect.left,
      rect.top,
      width,
      height,
      self.sourceDC,
      Int32(reference.atlasIndex) * WindowsProviderBranding.atlasCellSize,
      0,
      WindowsProviderBranding.atlasCellSize,
      WindowsProviderBranding.atlasCellSize,
      DWORD(SRCCOPY))
  }
}
