import Foundation
import WinSDK

enum WindowsWideString {
  static func withPointer<Result>(
    _ value: String,
    _ body: (UnsafePointer<WCHAR>) throws -> Result
  ) rethrows -> Result {
    try value.withCString(encodedAs: UTF16.self, body)
  }

  static func copy(_ value: String, to buffer: UnsafeMutablePointer<WCHAR>, capacity: Int) {
    guard capacity > 0 else { return }
    var units = Array(value.utf16.prefix(capacity - 1))
    if let last = units.last, (0xD800...0xDBFF).contains(last) {
      units.removeLast()
    }
    for index in 0..<capacity {
      buffer[index] = 0
    }
    for (index, unit) in units.enumerated() {
      buffer[index] = WCHAR(unit)
    }
  }

  static func setWindowText(_ window: HWND?, _ value: String) {
    self.withPointer(value) { pointer in
      _ = SetWindowTextW(window, pointer)
    }
  }
}
