import WinSDK

enum WindowsDashboardPalette {
  static let background = color(27, 26, 24)
  static let header = color(27, 26, 24)
  static let surface = color(35, 34, 32)
  static let card = color(35, 34, 32)
  static let cardHover = color(40, 39, 36)
  static let selected = color(46, 44, 41)
  static let pressed = color(52, 50, 46)
  static let track = color(46, 44, 41)
  static let border = color(46, 44, 41)
  static let primaryText = color(230, 226, 219)
  static let secondaryText = color(162, 156, 147)
  static let captionText = color(107, 102, 95)
  static let disabledText = color(82, 78, 72)
  static let sage = color(126, 143, 110)
  static let sageSurface = color(40, 45, 36)
  static let sageText = color(154, 171, 137)
  static let ochre = color(190, 154, 84)
  static let ochreSurface = color(50, 43, 30)
  static let ochreText = color(208, 176, 112)
  static let clay = color(168, 97, 79)
  static let claySurface = color(52, 34, 30)
  static let clayText = color(202, 127, 107)
  static let focus = color(211, 205, 195)

  static func progressColor(percent: Double) -> COLORREF {
    if percent >= 90 { return self.clay }
    if percent >= 70 { return self.ochre }
    return self.sage
  }

  private static func color(_ red: UInt32, _ green: UInt32, _ blue: UInt32) -> COLORREF {
    COLORREF(red | (green << 8) | (blue << 16))
  }
}

struct WindowsMeterFillGeometry: Equatable, Sendable {
  let left: Int32
  let right: Int32

  static func make(
    trackLeft: Int32,
    trackRight: Int32,
    usedPercent: Double,
    showUsed: Bool
  ) -> WindowsMeterFillGeometry? {
    let clampedUsed = min(100, max(0, usedPercent))
    let displayedPercent = showUsed ? clampedUsed : 100 - clampedUsed
    let fillWidth = Int32((Double(trackRight - trackLeft) * displayedPercent / 100).rounded())
    guard fillWidth > 0 else { return nil }
    return WindowsMeterFillGeometry(left: trackLeft, right: trackLeft + fillWidth)
  }
}

enum WindowsSpinnerPresentation {
  static let frameCount = 8
  static let frameIntervalMilliseconds: UINT = 180
  static let revolutionDurationMilliseconds = Int(frameIntervalMilliseconds) * frameCount
  static let dotOffsets: [(x: Int32, y: Int32)] = [
    (0, -7),
    (5, -5),
    (7, 0),
    (5, 5),
    (0, 7),
    (-5, 5),
    (-7, 0),
    (-5, -5),
  ]

  static func nextFrame(after frame: Int) -> Int {
    (frame + 1) % self.frameCount
  }
}

enum WindowsDashboardDrawing {
  static func roundedRect(
    dc: HDC?,
    rect: RECT,
    radius: Int32,
    fill: COLORREF,
    border: COLORREF? = nil,
    borderWidth: Int32 = 1
  ) {
    guard let brush = CreateSolidBrush(fill) else { return }
    let pen = CreatePen(Int32(PS_SOLID), borderWidth, border ?? fill)
    let oldBrush = SelectObject(dc, brush)
    let oldPen = pen.map { SelectObject(dc, $0) }
    _ = RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius, radius)
    if let oldPen { _ = SelectObject(dc, oldPen) }
    if let oldBrush { _ = SelectObject(dc, oldBrush) }
    if let pen { _ = DeleteObject(pen) }
    _ = DeleteObject(brush)
  }

  static func line(dc: HDC?, fromX: Int32, y: Int32, toX: Int32, color: COLORREF, width: Int32 = 1)
  {
    guard let pen = CreatePen(Int32(PS_SOLID), width, color) else { return }
    let oldPen = SelectObject(dc, pen)
    _ = MoveToEx(dc, fromX, y, nil)
    _ = LineTo(dc, toX, y)
    if let oldPen { _ = SelectObject(dc, oldPen) }
    _ = DeleteObject(pen)
  }

  static func iconGlyph(
    _ value: String,
    dc: HDC?,
    rect: RECT,
    color: COLORREF,
    font: HFONT?
  ) {
    _ = SetBkMode(dc, Int32(TRANSPARENT))
    _ = SetTextColor(dc, color)
    let oldFont = font.map { SelectObject(dc, $0) }
    let oldAlignment = SetTextAlign(dc, UINT(TA_CENTER | TA_BASELINE))
    let x = (rect.left + rect.right) / 2
    let y = (rect.top + rect.bottom) / 2 + (rect.bottom - rect.top) / 5
    WindowsWideString.withPointer(value) { pointer in
      _ = TextOutW(dc, x, y, pointer, Int32(value.utf16.count))
    }
    _ = SetTextAlign(dc, oldAlignment)
    if let oldFont { _ = SelectObject(dc, oldFont) }
  }

  static func progressRing(
    dc: HDC?,
    rect: RECT,
    frame: Int,
    activeColor: COLORREF,
    inactiveColor: COLORREF
  ) {
    let centerX = (rect.left + rect.right) / 2
    let centerY = (rect.top + rect.bottom) / 2
    let scale = max(1, min(rect.right - rect.left, rect.bottom - rect.top) / 18)
    let oldPen = SelectObject(dc, GetStockObject(Int32(NULL_PEN)))
    for (index, offset) in WindowsSpinnerPresentation.dotOffsets.enumerated() {
      let color =
        index == frame % WindowsSpinnerPresentation.frameCount
        ? activeColor : inactiveColor
      guard let brush = CreateSolidBrush(color) else { continue }
      let oldBrush = SelectObject(dc, brush)
      let x = centerX + offset.x * scale
      let y = centerY + offset.y * scale
      let radius = max(1, scale * 2)
      _ = Ellipse(dc, x - radius, y - radius, x + radius + 1, y + radius + 1)
      if let oldBrush { _ = SelectObject(dc, oldBrush) }
      _ = DeleteObject(brush)
    }
    if let oldPen { _ = SelectObject(dc, oldPen) }
  }

  static func text(
    _ value: String,
    dc: HDC?,
    rect: RECT,
    color: COLORREF,
    font: HFONT?,
    format: UINT
  ) {
    _ = SetBkMode(dc, Int32(TRANSPARENT))
    _ = SetTextColor(dc, color)
    let oldFont = font.map { SelectObject(dc, $0) }
    var drawingRect = rect
    WindowsWideString.withPointer(value) { pointer in
      _ = DrawTextW(dc, pointer, -1, &drawingRect, format | UINT(DT_NOPREFIX))
    }
    if let oldFont { _ = SelectObject(dc, oldFont) }
  }
}

private let codexBarMeterClassName = "CodexBarMeter"

private func codexBarMeterWindowProcedure(
  _ window: HWND?,
  _ message: UINT,
  _ wParam: WPARAM,
  _ lParam: LPARAM
) -> LRESULT {
  switch message {
  case UINT(WM_ERASEBKGND):
    return 1
  case UINT(WM_PAINT):
    guard let window else { return 0 }
    var paint = PAINTSTRUCT()
    let dc = BeginPaint(window, &paint)
    defer { _ = EndPaint(window, &paint) }

    var rect = RECT()
    guard GetClientRect(window, &rect) else { return 0 }
    let height = max(1, rect.bottom - rect.top)
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: rect,
      radius: height,
      fill: WindowsDashboardPalette.track)

    let storedPercent = max(0, min(100, GetWindowLongPtrW(window, GWLP_USERDATA)))
    let fillWidth = Int32((Int64(rect.right - rect.left) * Int64(storedPercent)) / 100)
    guard fillWidth > 0 else { return 0 }
    var fillRect = rect
    fillRect.right = min(rect.right, rect.left + max(height, fillWidth))
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: fillRect,
      radius: height,
      fill: WindowsDashboardPalette.progressColor(percent: Double(storedPercent)))
    return 0
  default:
    return DefWindowProcW(window, message, wParam, lParam)
  }
}

enum WindowsDashboardMeter {
  static func register(instance: HINSTANCE?) -> Bool {
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.style = UINT(CS_HREDRAW | CS_VREDRAW)
    windowClass.lpfnWndProc = codexBarMeterWindowProcedure
    windowClass.hInstance = instance
    windowClass.hCursor = LoadCursorW(nil, LPCWSTR(bitPattern: 32512))

    return WindowsWideString.withPointer(codexBarMeterClassName) { className in
      windowClass.lpszClassName = className
      let result = RegisterClassExW(&windowClass)
      return result != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS)
    }
  }

  static func create(parent: HWND?, instance: HINSTANCE?) -> HWND? {
    WindowsWideString.withPointer(codexBarMeterClassName) { className in
      CreateWindowExW(
        0,
        className,
        nil,
        DWORD(WS_CHILD | WS_VISIBLE),
        0,
        0,
        0,
        0,
        parent,
        nil,
        instance,
        nil)
    }
  }

  static func setPercent(_ percent: Double, for control: HWND?) {
    guard let control else { return }
    let value = LONG_PTR(Int(max(0, min(100, percent)).rounded()))
    _ = SetWindowLongPtrW(control, GWLP_USERDATA, value)
    _ = InvalidateRect(control, nil, true)
  }
}
