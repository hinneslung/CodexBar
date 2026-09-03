#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  struct WindowsMeterGeometryTests {
    @Test("refresh spinner advances and wraps its animation frame")
    func refreshSpinnerWraps() {
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
