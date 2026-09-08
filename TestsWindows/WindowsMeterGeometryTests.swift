#if canImport(CodexBarWindows)
import Testing
import WinSDK
@testable import CodexBarWindows

struct WindowsMeterGeometryTests {
    @Test(arguments: [96, 120, 144, 168, 192, 240, 288])
    func `spinner size follows DPI once and stays centered inside its hit target`(dpi: Int32) throws {
        func scaled(_ value: Int32) -> Int32 {
            Int32((Double(value * dpi) / 96).rounded())
        }
        for logicalDiameter: Int32 in [14, 18] {
            let diameter = scaled(logicalDiameter)
            let rect = RECT(left: 30, top: 70, right: 30 + scaled(34), bottom: 70 + scaled(40))
            let dots = WindowsSpinnerPresentation.dotRects(in: rect, diameter: diameter)
            #expect(dots.count == 8)
            let left = try #require(dots.map(\.left).min())
            let right = try #require(dots.map(\.right).max())
            let top = try #require(dots.map(\.top).min())
            let bottom = try #require(dots.map(\.bottom).max())
            #expect(right - left == diameter)
            #expect(bottom - top == diameter)
            #expect(abs(left + right - rect.left - rect.right) <= 1)
            #expect(abs(top + bottom - rect.top - rect.bottom) <= 1)
            #expect(left >= rect.left && right <= rect.right)
            #expect(top >= rect.top && bottom <= rect.bottom)
        }
    }

    @Test
    func `spinner fits a smaller checkbox and ignores empty bounds`() {
        let rect = RECT(left: 0, top: 0, right: 12, bottom: 10)
        let dots = WindowsSpinnerPresentation.dotRects(in: rect, diameter: 18)
        #expect(dots.allSatisfy { $0.left >= 0 && $0.right <= 12 && $0.top >= 0 && $0.bottom <= 10 })
        #expect(WindowsSpinnerPresentation.dotRects(in: RECT(), diameter: 18).isEmpty)
    }

    @Test
    func `refresh spinner advances and wraps its animation frame`() {
        var frame = 0
        for expected in 1..<WindowsSpinnerPresentation.frameCount {
            frame = WindowsSpinnerPresentation.nextFrame(after: frame)
            #expect(frame == expected)
        }
        #expect(WindowsSpinnerPresentation.nextFrame(after: frame) == 0)
        #expect(WindowsSpinnerPresentation.frameIntervalMilliseconds == 180)
        #expect(WindowsSpinnerPresentation.revolutionDurationMilliseconds == 1440)
    }

    @Test
    func `remaining mode burns inward from the right edge`() {
        let full = WindowsMeterFillGeometry.make(
            trackLeft: 10,
            trackRight: 110,
            usedPercent: 0,
            showUsed: false)
        let partiallyUsed = WindowsMeterFillGeometry.make(
            trackLeft: 10,
            trackRight: 110,
            usedPercent: 37,
            showUsed: false)

        #expect(full == WindowsMeterFillGeometry(left: 10, right: 110))
        #expect(partiallyUsed == WindowsMeterFillGeometry(left: 10, right: 73))
    }

    @Test
    func `used mode grows outward from the left edge`() {
        let fill = WindowsMeterFillGeometry.make(
            trackLeft: 10,
            trackRight: 110,
            usedPercent: 37,
            showUsed: true)

        #expect(fill == WindowsMeterFillGeometry(left: 10, right: 47))
    }
}
#endif
