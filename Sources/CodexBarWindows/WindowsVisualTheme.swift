import WinSDK

enum WindowsVisualTheme {
  private static let immersiveDarkModeAttribute: DWORD = 20
  private static let windowCornerPreferenceAttribute: DWORD = 33
  private static let roundedCornerPreference: DWORD = 2

  /// Requests modern non-client styling. Unsupported Windows versions simply ignore these attributes.
  static func apply(to window: HWND?) {
    guard let window else { return }

    var darkMode: Int32 = 1
    _ = withUnsafePointer(to: &darkMode) { value in
      DwmSetWindowAttribute(
        window,
        self.immersiveDarkModeAttribute,
        value,
        DWORD(MemoryLayout<Int32>.size))
    }

    var cornerPreference = self.roundedCornerPreference
    _ = withUnsafePointer(to: &cornerPreference) { value in
      DwmSetWindowAttribute(
        window,
        self.windowCornerPreferenceAttribute,
        value,
        DWORD(MemoryLayout<DWORD>.size))
    }
  }

  static func apply(toControl control: HWND?) {
    guard let control else { return }
    WindowsWideString.withPointer("DarkMode_Explorer") { theme in
      _ = SetWindowTheme(control, theme, nil)
    }
  }
}
