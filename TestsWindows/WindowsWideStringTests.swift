import Testing

@testable import CodexBarWindows

@Suite("Windows wide strings")
struct WindowsWideStringTests {
  @Test("copy reserves a terminator and never splits a surrogate pair")
  func copyPreservesUnicodeScalarBoundaries() {
    var buffer = [UInt16](repeating: 0xFFFF, count: 4)

    buffer.withUnsafeMutableBufferPointer { pointer in
      WindowsWideString.copy("AB😀", to: pointer.baseAddress!, capacity: pointer.count)
    }

    #expect(buffer == [65, 66, 0, 0])
  }
}
