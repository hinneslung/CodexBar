import Foundation
import WinSDK

/// Owns file-loaded icon handles for as long as a tray registration or window class may reference them.
final class WindowsApplicationIcon: @unchecked Sendable {
  let large: HICON?
  let small: HICON?
  let usesBundledIcon: Bool

  private let ownsLarge: Bool
  private let ownsSmall: Bool
  private var previousClassLarge: ULONG_PTR = 0
  private var previousClassSmall: ULONG_PTR = 0
  private var isApplied = false

  static func load() -> WindowsApplicationIcon {
    let resourceURL =
      Bundle.module.url(forResource: "CodexBar", withExtension: "ico")
      ?? Bundle.module.url(
        forResource: "CodexBar",
        withExtension: "ico",
        subdirectory: "Resources")
    let large = resourceURL.flatMap {
      self.loadIcon(url: $0, size: self.systemIconSize(small: false))
    }
    let small = resourceURL.flatMap {
      self.loadIcon(url: $0, size: self.systemIconSize(small: true))
    }
    let fallback = LoadIconW(nil, LPCWSTR(bitPattern: 32512))
    return WindowsApplicationIcon(
      large: large ?? fallback,
      small: small ?? fallback,
      usesBundledIcon: large != nil && small != nil,
      ownsLarge: large != nil,
      ownsSmall: small != nil)
  }

  private init(
    large: HICON?,
    small: HICON?,
    usesBundledIcon: Bool,
    ownsLarge: Bool,
    ownsSmall: Bool
  ) {
    self.large = large
    self.small = small
    self.usesBundledIcon = usesBundledIcon
    self.ownsLarge = ownsLarge
    self.ownsSmall = ownsSmall
  }

  deinit {
    if self.ownsSmall, let small = self.small {
      _ = DestroyIcon(small)
    }
    if self.ownsLarge, let large = self.large {
      _ = DestroyIcon(large)
    }
  }

  func apply(to window: HWND?) {
    guard !self.isApplied, let window else { return }
    if let large = self.large {
      _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: large)))
      self.previousClassLarge = SetClassLongPtrW(
        window, GCLP_HICON, LONG_PTR(Int(bitPattern: large)))
    }
    if let small = self.small {
      _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: small)))
      self.previousClassSmall = SetClassLongPtrW(
        window, GCLP_HICONSM, LONG_PTR(Int(bitPattern: small)))
    }
    self.isApplied = true
  }

  func remove(from window: HWND?) {
    guard self.isApplied, let window else { return }
    _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_BIG), 0)
    _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(ICON_SMALL), 0)
    _ = SetClassLongPtrW(window, GCLP_HICON, LONG_PTR(bitPattern: self.previousClassLarge))
    _ = SetClassLongPtrW(window, GCLP_HICONSM, LONG_PTR(bitPattern: self.previousClassSmall))
    self.isApplied = false
  }

  private static func loadIcon(url: URL, size: Int32) -> HICON? {
    WindowsWideString.withPointer(url.path) { path in
      guard
        let handle = LoadImageW(
          nil,
          path,
          UINT(IMAGE_ICON),
          size,
          size,
          UINT(LR_LOADFROMFILE))
      else { return nil }
      return handle.assumingMemoryBound(to: HICON__.self)
    }
  }

  private static func systemIconSize(small: Bool) -> Int32 {
    let metric = small ? SM_CXSMICON : SM_CXICON
    return max(16, GetSystemMetrics(metric))
  }
}
