import Foundation
import WinSDK

private let codexBarPopupClassName = "CodexBarPopupWindow"
private let windowsSecureRichEditAvailable: Bool = WindowsWideString.withPointer("Msftedit.dll") {
  LoadLibraryW($0) != nil
}

private func codexBarPopupWindowProcedure(
  _ window: HWND?,
  _ message: UINT,
  _ wParam: WPARAM,
  _ lParam: LPARAM
) -> LRESULT {
  WindowsTrayApplication.current?.handlePopupMessage(
    window: window,
    message: message,
    wParam: wParam,
    lParam: lParam) ?? DefWindowProcW(window, message, wParam, lParam)
}

final class WindowsPopupWindow {
  private enum Metrics {
    static let width: Int32 = 360
    static let minimumHeight: Int32 = 190
    static let maximumHeight: Int32 = 580
    static let headerHeight: Int32 = 42
    static let footerHeight: Int32 = 38
    static let overviewRowHeight: Int32 = 60
    static let switcherRowHeight: Int32 = 36
    static let settingsGlobalHeight: Int32 = 50
    static let settingsSectionHeaderHeight: Int32 = 28
    static let settingsSearchHeight: Int32 = 38
    static let settingsRowHeight: Int32 = 46
    static let horizontalInset: Int32 = 16
  }

  private static let deferredHideTimerID: UINT_PTR = 41
  private static let postTrayActivationTimerID: UINT_PTR = 42
  private static let refreshAnimationTimerID: UINT_PTR = 43
  private static let postTrayActivationDelayMilliseconds: UINT = 20
  private static let storedSecretPlaceholder = "••••••••"
  private static let refreshIconGlyph = "\u{E72C}"
  private static let searchIconGlyph = "\u{E721}"
  private static let settingsIconGlyph = "\u{E713}"

  private enum Page: Equatable {
    case overview
    case provider(Int)
    case switcher
    case settings
    case configure(WindowsProviderID)
  }

  private enum Action {
    case refresh
    case settings
    case switcher
    case back
    case provider(Int)
    case toggleUsageBarsShowUsed
    case toggleRunAtStartup
    case toggleProvider(WindowsProviderID)
    case moveProvider(WindowsProviderID, Int)
    case moveProviderToTop(WindowsProviderID)
    case configureProvider(WindowsProviderID)
    case saveProvider(WindowsProviderID)
    case clearProvider(WindowsProviderID)
    case toggleCredentialHelp
    case openProviderResource(WindowsProviderID)
  }

  private struct HitTarget {
    let rect: RECT
    let action: Action
  }

  private(set) var window: HWND?
  private let instance: HINSTANCE?
  private let automaticallyHides =
    ProcessInfo.processInfo.environment["CODEXBAR_WINDOWS_KEEP_OPEN"] != "1"
  private let usesTargetableQAWindow =
    ProcessInfo.processInfo.environment["CODEXBAR_WINDOWS_QA_TARGETABLE"] == "1"
  private var presentation = WindowsDashboardPresentation.loading()
  private var configuration = WindowsAppConfiguration.defaults
  private var page: Page = .overview
  private var hitTargets: [HitTarget] = []
  private var scrollOffset: Int32 = 0
  private var dpi: UINT = 96
  private var bodyFont: HFONT?
  private var bodySemiboldFont: HFONT?
  private var metricFont: HFONT?
  private var secondaryFont: HFONT?
  private var systemIconFont: HFONT?
  private var backgroundBrush: HBRUSH?
  private var editBrush: HBRUSH?
  private var configurationSourceControl: HWND?
  private var configurationCredentialControl: HWND?
  private var configurationFieldControls: [String: HWND] = [:]
  private var configurationCapabilities: WindowsProviderConfigurationSchema?
  private var configurationStatus: WindowsUpstreamConfigurationStatus?
  private var configurationCapabilitiesError: String?
  private var configurationDraftValidationError: String?
  private var configurationCanClearCredential = false
  private var configurationPendingRequestID: Foundation.UUID?
  private var refreshIntervalControl: HWND?
  private var disabledProviderSearchControl: HWND?
  private var disabledProviderSearchQuery = ""
  private var configurationSourceDraft: String?
  private var configurationCredentialSetDraftID: String?
  private var configurationCredentialSelectionTouched = false
  private var configurationCredentialHelpExpanded = false
  private var configurationLastAppliedProvider: WindowsProviderID?
  private var configurationReturnPage: Page = .settings
  private let availableWSLDistributions = WindowsWSLDistributionRegistry.names()
  private let providerLogoAtlas = WindowsProviderLogoAtlas.load()
  private var activationPolicy = WindowsPopupActivationPolicy()
  private var refreshAnimationFrame = 0

  init(instance: HINSTANCE?) {
    self.instance = instance
  }

  var isVisible: Bool {
    self.window.map { IsWindowVisible($0) != false } ?? false
  }

  func create() -> Bool {
    guard self.window == nil else { return true }
    guard self.registerWindowClass() else { return false }
    self.backgroundBrush = CreateSolidBrush(WindowsDashboardPalette.background)
    self.editBrush = CreateSolidBrush(WindowsDashboardPalette.surface)
    let extendedStyle =
      DWORD(WS_EX_TOPMOST)
      | (self.usesTargetableQAWindow ? DWORD(WS_EX_APPWINDOW) : DWORD(WS_EX_TOOLWINDOW))
    self.window = WindowsWideString.withPointer(codexBarPopupClassName) { className in
      WindowsWideString.withPointer("CodexBar") { title in
        CreateWindowExW(
          extendedStyle,
          className,
          title,
          DWORD(WS_POPUP) | DWORD(WS_CLIPCHILDREN),
          Int32(CW_USEDEFAULT),
          Int32(CW_USEDEFAULT),
          Metrics.width,
          Metrics.minimumHeight,
          nil,
          nil,
          self.instance,
          nil)
      }
    }
    guard let window = self.window else { return false }
    self.dpi = GetDpiForWindow(window)
    self.createFonts()
    WindowsVisualTheme.apply(to: window)
    self.updateRefreshAnimationTimer()
    return true
  }

  func toggleAnchoredFromTray() {
    switch self.activationPolicy.trayActivated(isPopupVisible: self.isVisible) {
    case .showFromTray:
      self.showAnchored()
      guard let window = self.window, self.isVisible else {
        self.activationPolicy.popupHidden()
        return
      }
      _ = SetTimer(
        window,
        Self.postTrayActivationTimerID,
        Self.postTrayActivationDelayMilliseconds,
        nil)
    case .hide:
      self.hide()
    case .ignoreDuplicateTrayActivation:
      break
    case .scheduleDeferredHide, .cancelDeferredHideAndReactivate, .none:
      assertionFailure("Unexpected tray activation action")
    }
  }

  func showAnchored() {
    guard self.create(), let window = self.window else { return }
    if self.page == .settings {
      self.ensureSettingsControls()
    }
    _ = KillTimer(window, Self.deferredHideTimerID)
    let size = self.desiredWindowSize()
    let origin = self.anchoredOrigin(size: size)
    _ = SetWindowPos(
      window,
      nil,
      origin.x,
      origin.y,
      size.cx,
      size.cy,
      UINT(SWP_SHOWWINDOW | SWP_NOZORDER))
    _ = SetForegroundWindow(window)
    self.layoutConfigurationControls()
    _ = InvalidateRect(window, nil, false)
  }

  func handleDialogMessage(_ message: inout MSG) -> Bool {
    guard self.page == .settings || self.isProviderConfigurationPage,
      let window = self.window
    else {
      return false
    }
    if message.message == UINT(WM_KEYDOWN), message.wParam == WPARAM(VK_ESCAPE) {
      _ = self.handleKeyDown(wParam: message.wParam)
      return true
    }
    if message.message == UINT(WM_KEYDOWN) {
      let focusedControl = GetFocus()
      switch WindowsTextInputKeyboardPolicy.action(
        virtualKey: UInt32(message.wParam),
        controlDown: GetKeyState(Int32(VK_CONTROL)) < 0,
        focusedControlClass: Self.windowClassName(focusedControl))
      {
      case .selectAll:
        _ = SendMessageW(focusedControl, UINT(EM_SETSEL), 0, -1)
        return true
      case .refresh:
        WindowsTrayApplication.current?.requestRefresh()
        return true
      case .dispatchToFocusedControl:
        return false
      case .dialogNavigation:
        break
      }
    }
    return IsDialogMessageW(window, &message)
  }

  func hide() {
    guard let window = self.window else { return }
    self.activationPolicy.popupHidden()
    _ = KillTimer(window, Self.deferredHideTimerID)
    _ = KillTimer(window, Self.postTrayActivationTimerID)
    _ = ShowWindow(window, SW_HIDE)
  }

  func destroy() {
    self.destroyConfigurationControls()
    if let window = self.window {
      _ = KillTimer(window, Self.refreshAnimationTimerID)
      _ = DestroyWindow(window)
    }
    self.window = nil
    self.releaseFonts()
    if let backgroundBrush = self.backgroundBrush { _ = DeleteObject(backgroundBrush) }
    self.backgroundBrush = nil
    if let editBrush = self.editBrush { _ = DeleteObject(editBrush) }
    self.editBrush = nil
  }

  func update(_ presentation: WindowsDashboardPresentation) {
    self.presentation = presentation
    self.updateRefreshAnimationTimer()
    if case .provider(let index) = self.page, index >= presentation.rows.count {
      self.page = .overview
    }
    self.resizeForCurrentPage()
    _ = InvalidateRect(self.window, nil, false)
  }

  func updateConfiguration(_ configuration: WindowsAppConfiguration) {
    self.configuration = configuration
    if case .configure(let provider) = self.page,
      !configuration.providers.contains(where: { $0.id == provider })
    {
      self.destroyConfigurationControls()
      self.page = .settings
    }
    if self.page == .settings {
      self.ensureSettingsControls()
      self.updateRefreshIntervalControlText()
    }
    self.resizeForCurrentPage()
    _ = InvalidateRect(self.window, nil, false)
  }

  func completeProviderConfigurationTask(
    requestID: Foundation.UUID,
    provider: WindowsProviderID,
    status: WindowsUpstreamConfigurationStatus?,
    didApply: Bool,
    safeErrorText: String?,
    canClearCredential: Bool
  ) {
    guard self.configurationPendingRequestID == requestID,
      case .configure(let currentProvider) = self.page,
      currentProvider == provider
    else { return }
    self.configurationPendingRequestID = nil
    self.configurationCapabilitiesError = safeErrorText
    self.configurationDraftValidationError = nil
    self.configurationCanClearCredential = canClearCredential
    var credentialSelectionChanged = false
    if let status {
      self.configurationStatus = status
      if !self.configurationCredentialSelectionTouched {
        let previousCredentialSetID = self.configurationCredentialSetDraftID
        self.configurationCredentialSetDraftID = status.credentialSetID
        credentialSelectionChanged = previousCredentialSetID != status.credentialSetID
        self.updateCredentialMethodSelection()
      }
    }
    if didApply {
      if let schema = WindowsProviderConfigurationCatalog.byProvider[provider] {
        self.configurationCapabilities = schema
        self.configurationCredentialSetDraftID = status?.credentialSetID
        self.configurationCredentialSelectionTouched = false
        self.updateCredentialMethodSelection()
        self.rebuildProviderFieldControls()
      }
      self.configurationLastAppliedProvider = provider
    } else if credentialSelectionChanged {
      self.configurationCredentialHelpExpanded = false
      self.rebuildProviderFieldControls()
    }
    self.resizeForCurrentPage()
    self.layoutConfigurationControls()
    _ = InvalidateRect(self.window, nil, false)
  }

  func handleMessage(
    window: HWND?,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM
  ) -> LRESULT {
    switch message {
    case UINT(WM_PAINT):
      self.paint()
      return 0
    case UINT(WM_ERASEBKGND):
      return 1
    case UINT(WM_LBUTTONUP):
      self.activate(at: Self.point(from: lParam))
      return 0
    case UINT(WM_MOUSEWHEEL):
      self.scroll(delta: Self.wheelDelta(from: wParam))
      return 0
    case UINT(WM_KEYDOWN):
      return self.handleKeyDown(wParam: wParam)
    case UINT(WM_COMMAND):
      if let sourceControl = self.configurationSourceControl,
        sourceControl == HWND(bitPattern: UInt(bitPattern: Int(lParam))),
        UInt16(truncatingIfNeeded: wParam >> 16) == UInt16(CBN_SELCHANGE)
      {
        let selection = Int(SendMessageW(sourceControl, UINT(CB_GETCURSEL), 0, 0))
        if selection >= 0, selection <= self.availableWSLDistributions.count {
          self.configurationSourceDraft =
            selection == 0
            ? nil
            : self.availableWSLDistributions[selection - 1]
          self.configurationCapabilitiesError = nil
          self.configurationDraftValidationError = nil
          self.resizeForCurrentPage()
          self.layoutConfigurationControls()
          _ = InvalidateRect(self.window, nil, false)
        }
        return 0
      }
      if let credentialControl = self.configurationCredentialControl,
        credentialControl == HWND(bitPattern: UInt(bitPattern: Int(lParam))),
        UInt16(truncatingIfNeeded: wParam >> 16) == UInt16(CBN_SELCHANGE),
        let schema = self.configurationCapabilities
      {
        let selection = Int(SendMessageW(credentialControl, UINT(CB_GETCURSEL), 0, 0))
        let credentialSets = schema.manualCredentialSets
        guard selection >= 0, selection <= credentialSets.count else { return 0 }
        self.configurationCredentialSetDraftID =
          selection == 0 ? nil : credentialSets[selection - 1].id
        self.configurationCredentialSelectionTouched = true
        self.configurationCredentialHelpExpanded = false
        self.configurationCapabilitiesError = nil
        self.configurationDraftValidationError = nil
        self.rebuildProviderFieldControls()
        self.resizeForCurrentPage()
        self.layoutConfigurationControls()
        _ = InvalidateRect(self.window, nil, false)
        return 0
      }
      if let fieldEntry = self.configurationFieldControls.first(where: {
        $0.value == HWND(bitPattern: UInt(bitPattern: Int(lParam)))
      }), let field = self.activeConfigurationFields.first(where: { $0.id == fieldEntry.key }) {
        let notification = UInt16(truncatingIfNeeded: wParam >> 16)
        if notification == UInt16(EN_SETFOCUS), field.secret,
          Self.windowText(fieldEntry.value) == Self.storedSecretPlaceholder
        {
          WindowsWideString.withPointer("") { pointer in
            _ = SetWindowTextW(fieldEntry.value, pointer)
          }
        }
        if notification == UInt16(EN_CHANGE) {
          self.configurationCapabilitiesError = nil
          self.configurationDraftValidationError = nil
          self.resizeForCurrentPage()
          _ = InvalidateRect(self.window, nil, false)
        }
        if notification == UInt16(EN_KILLFOCUS), field.secret,
          Self.windowText(fieldEntry.value).isEmpty, self.isConfigured(field)
        {
          WindowsWideString.withPointer(Self.storedSecretPlaceholder) { pointer in
            _ = SetWindowTextW(fieldEntry.value, pointer)
          }
        }
        return 0
      }
      if let refreshControl = self.refreshIntervalControl,
        refreshControl == HWND(bitPattern: UInt(bitPattern: Int(lParam)))
      {
        let notification = UInt16(truncatingIfNeeded: wParam >> 16)
        let text = Self.windowText(refreshControl)
        if notification == UInt16(EN_CHANGE),
          let minutes = WindowsAppConfiguration.parsedRefreshIntervalMinutes(text)
        {
          _ = WindowsTrayApplication.current?.updateRefreshIntervalMinutes(minutes)
          return 0
        }
        if notification == UInt16(EN_KILLFOCUS) {
          self.updateRefreshIntervalControlText()
        }
        return 0
      }
      if let searchControl = self.disabledProviderSearchControl,
        searchControl == HWND(bitPattern: UInt(bitPattern: Int(lParam)))
      {
        let notification = UInt16(truncatingIfNeeded: wParam >> 16)
        if notification == UInt16(EN_CHANGE) {
          self.disabledProviderSearchQuery = Self.windowText(searchControl)
          self.scrollOffset = min(self.scrollOffset, self.maximumScrollOffset())
          self.resizeForCurrentPage()
          self.layoutConfigurationControls()
          _ = InvalidateRect(self.window, nil, false)
        }
        return 0
      }
      return 0
    case UINT(WM_CTLCOLOREDIT):
      guard let editBrush = self.editBrush, let dc = HDC(bitPattern: UInt(wParam)) else { return 0 }
      _ = SetTextColor(dc, WindowsDashboardPalette.primaryText)
      _ = SetBkColor(dc, WindowsDashboardPalette.surface)
      return LRESULT(Int(bitPattern: editBrush))
    case UINT(WM_ACTIVATE):
      let isInactive = UInt16(truncatingIfNeeded: wParam) == UInt16(WA_INACTIVE)
      if isInactive, !self.hasDirtyProviderDraft,
        self.activationPolicy.deactivated(automaticallyHides: self.automaticallyHides)
          == .scheduleDeferredHide
      {
        _ = SetTimer(self.window, Self.deferredHideTimerID, 120, nil)
      } else if let window = self.window {
        _ = KillTimer(window, Self.deferredHideTimerID)
      }
      return 0
    case UINT(WM_TIMER):
      if UINT_PTR(wParam) == Self.deferredHideTimerID {
        if self.hasDirtyProviderDraft {
          if let window = self.window { _ = KillTimer(window, Self.deferredHideTimerID) }
          return 0
        }
        switch self.activationPolicy.deferredHideTimerFired(isPopupVisible: self.isVisible) {
        case .hide:
          self.hide()
        case .cancelDeferredHideAndReactivate:
          self.completePostTrayActivation()
        case .showFromTray, .ignoreDuplicateTrayActivation, .scheduleDeferredHide, .none:
          break
        }
      } else if UINT_PTR(wParam) == Self.postTrayActivationTimerID {
        if let window = self.window {
          _ = KillTimer(window, Self.postTrayActivationTimerID)
        }
        if self.activationPolicy.postTrayActivationTimerFired(isPopupVisible: self.isVisible)
          == .cancelDeferredHideAndReactivate
        {
          self.completePostTrayActivation()
        }
      } else if UINT_PTR(wParam) == Self.refreshAnimationTimerID {
        self.refreshAnimationFrame = WindowsSpinnerPresentation.nextFrame(
          after: self.refreshAnimationFrame)
        if let window = self.window {
          var client = RECT()
          if GetClientRect(window, &client) {
            var refreshRect = self.refreshIndicatorRect(client: client)
            _ = InvalidateRect(window, &refreshRect, false)
          }
        }
      }
      return 0
    case UINT(WM_DPICHANGED):
      self.handleDPIChanged(lParam: lParam)
      return 0
    case UINT(WM_SIZE):
      self.layoutConfigurationControls()
      return 0
    case UINT(WM_THEMECHANGED), UINT(WM_SETTINGCHANGE):
      WindowsVisualTheme.apply(to: self.window)
      _ = InvalidateRect(self.window, nil, false)
      return 0
    case UINT(WM_CLOSE):
      self.hide()
      return 0
    default:
      return DefWindowProcW(window, message, wParam, lParam)
    }
  }

  private func completePostTrayActivation() {
    guard let window = self.window, self.isVisible else { return }
    _ = KillTimer(window, Self.deferredHideTimerID)
    _ = KillTimer(window, Self.postTrayActivationTimerID)
    _ = SetForegroundWindow(window)
    _ = SetActiveWindow(window)
  }

  private func paint() {
    guard let window = self.window else { return }
    var paint = PAINTSTRUCT()
    let paintDC = BeginPaint(window, &paint)
    defer { _ = EndPaint(window, &paint) }

    var client = RECT()
    guard GetClientRect(window, &client) else { return }
    let width = max(1, client.right - client.left)
    let height = max(1, client.bottom - client.top)
    guard let memoryDC = CreateCompatibleDC(paintDC),
      let bitmap = CreateCompatibleBitmap(paintDC, width, height)
    else {
      return
    }
    let previousBitmap = SelectObject(memoryDC, bitmap)
    defer {
      if let previousBitmap { _ = SelectObject(memoryDC, previousBitmap) }
      _ = DeleteObject(bitmap)
      _ = DeleteDC(memoryDC)
    }
    if let backgroundBrush = self.backgroundBrush {
      _ = FillRect(memoryDC, &client, backgroundBrush)
    }
    self.hitTargets = []
    switch self.page {
    case .overview:
      self.drawOverview(dc: memoryDC, client: client)
    case .provider(let index):
      self.drawProvider(dc: memoryDC, client: client, index: index)
    case .switcher:
      self.drawSwitcher(dc: memoryDC, client: client)
    case .settings:
      self.drawSettings(dc: memoryDC, client: client)
    case .configure(let provider):
      self.drawProviderConfiguration(dc: memoryDC, client: client, provider: provider)
    }
    _ = BitBlt(paintDC, 0, 0, width, height, memoryDC, 0, 0, DWORD(SRCCOPY))
  }

  private func drawOverview(dc: HDC?, client: RECT) {
    let contentState = self.beginContentClip(dc: dc, client: client)
    var y = -self.scrollOffset
    for (index, row) in self.presentation.rows.enumerated() {
      let rect = RECT(
        left: 0,
        top: y,
        right: client.right,
        bottom: y + self.scaled(Metrics.overviewRowHeight))
      if rect.bottom > 0,
        rect.top < client.bottom - self.scaled(Metrics.footerHeight)
      {
        self.drawOverviewRow(dc: dc, rect: rect, row: row, index: index)
        if let hitRect = self.contentHitRect(rect, client: client) {
          self.hitTargets.append(HitTarget(rect: hitRect, action: .provider(index)))
        }
      }
      y = rect.bottom
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawFooter(dc: dc, client: client)
  }

  private func drawOverviewRow(
    dc: HDC?,
    rect: RECT,
    row: WindowsProviderRowPresentation,
    index: Int
  ) {
    let inset = self.scaled(Metrics.horizontalInset)
    let badge = RECT(
      left: inset,
      top: rect.top + self.scaled(10),
      right: inset + self.scaled(16),
      bottom: rect.top + self.scaled(26))
    self.drawProviderLogo(dc: dc, provider: row.provider, rect: badge)

    let governing = row.governingWindow
    let metric =
      governing.map {
        $0.displayedPercentText(showUsed: self.configuration.usageBarsShowUsed)
      }
      ?? WindowsProviderBalanceFormatter.compact(row.balanceText)
      ?? "—"
    WindowsDashboardDrawing.text(
      row.provider.displayName,
      dc: dc,
      rect: RECT(
        left: badge.right + self.scaled(8),
        top: rect.top + self.scaled(7),
        right: rect.right - self.scaled(136),
        bottom: rect.top + self.scaled(27)),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodySemiboldFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    WindowsDashboardDrawing.text(
      metric,
      dc: dc,
      rect: RECT(
        left: rect.right - self.scaled(132),
        top: rect.top + self.scaled(6),
        right: rect.right - inset,
        bottom: rect.top + self.scaled(28)),
      color: row.errorText.isEmpty
        ? WindowsDashboardPalette.primaryText : WindowsDashboardPalette.clayText,
      font: self.metricFont,
      format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))

    if let governing {
      let track = RECT(
        left: inset,
        top: rect.top + self.scaled(33),
        right: rect.right - inset,
        bottom: rect.top + self.scaled(36))
      self.drawMeter(dc: dc, rect: track, usedPercent: governing.usedPercent)
    }
    let context = row.overviewStatusText
    let reset = governing?.overviewResetText ?? ""
    let detailTop = rect.top + self.scaled(38)
    let detailBottom = rect.bottom - self.scaled(3)
    let resetLeft = rect.left + (rect.right - rect.left) * 55 / 100
    if !context.isEmpty {
      WindowsDashboardDrawing.text(
        context,
        dc: dc,
        rect: RECT(
          left: inset,
          top: detailTop,
          right: reset.isEmpty ? rect.right - inset : resetLeft - self.scaled(8),
          bottom: detailBottom),
        color: row.errorText.isEmpty
          ? WindowsDashboardPalette.secondaryText : WindowsDashboardPalette.clayText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    }
    if !reset.isEmpty {
      WindowsDashboardDrawing.text(
        reset,
        dc: dc,
        rect: RECT(
          left: context.isEmpty ? inset : resetLeft,
          top: detailTop,
          right: rect.right - inset,
          bottom: detailBottom),
        color: WindowsDashboardPalette.captionText,
        font: self.secondaryFont,
        format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    }

    if index + 1 < self.presentation.rows.count {
      WindowsDashboardDrawing.line(
        dc: dc,
        fromX: inset,
        y: rect.bottom - 1,
        toX: rect.right - inset,
        color: WindowsDashboardPalette.border)
    }
  }

  private func drawProvider(dc: HDC?, client: RECT, index: Int) {
    guard index < self.presentation.rows.count else { return }
    let row = self.presentation.rows[index]
    let contentState = self.beginContentClip(dc: dc, client: client)
    let inset = self.scaled(Metrics.horizontalInset)
    var y = self.scaled(Metrics.headerHeight + 12) - self.scrollOffset

    let plan = row.planText.replacingOccurrences(of: "Plan: ", with: "")
    let identity = [row.accountText, plan].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    if !identity.isEmpty {
      WindowsDashboardDrawing.text(
        identity,
        dc: dc,
        rect: RECT(left: inset, top: y, right: client.right - inset, bottom: y + self.scaled(18)),
        color: WindowsDashboardPalette.secondaryText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
      y += self.scaled(28)
    }

    for usage in row.windows {
      self.drawDetailWindow(dc: dc, client: client, y: y, usage: usage)
      y += self.scaled(52)
    }
    if !row.balanceText.isEmpty {
      self.drawRule(dc: dc, client: client, y: y)
      y += self.scaled(10)
      self.drawLabelValue(dc: dc, client: client, y: y, label: "Balance", value: row.balanceText)
      y += self.scaled(34)
    }
    self.drawRule(dc: dc, client: client, y: y)
    y += self.scaled(10)
    let sourceValue =
      self.configuration.providers.first(where: { $0.id == row.provider }).map {
        WindowsProviderSettingsPresentation.subtitle(
          configuration: $0,
          sourceText: row.sourceText)
      } ?? row.sourceText
    self.drawLabelValue(
      dc: dc,
      client: client,
      y: y,
      label: "Source",
      value: sourceValue)
    y += self.scaled(28)
    if !row.errorText.isEmpty {
      WindowsDashboardDrawing.text(
        row.errorText,
        dc: dc,
        rect: RECT(left: inset, top: y, right: client.right - inset, bottom: y + self.scaled(46)),
        color: WindowsDashboardPalette.clayText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_END_ELLIPSIS))
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawHeader(dc: dc, client: client, title: row.provider.displayName, provider: row.provider)
    self.drawFooter(
      dc: dc,
      client: client,
      backAction: .back,
      settingsAction: .configureProvider(row.provider))
  }

  private func drawDetailWindow(
    dc: HDC?,
    client: RECT,
    y: Int32,
    usage: WindowsUsageWindowPresentation
  ) {
    let inset = self.scaled(Metrics.horizontalInset)
    WindowsDashboardDrawing.text(
      usage.label,
      dc: dc,
      rect: RECT(
        left: inset, top: y, right: client.right - self.scaled(80), bottom: y + self.scaled(18)),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodyFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    WindowsDashboardDrawing.text(
      usage.displayedPercentText(showUsed: self.configuration.usageBarsShowUsed),
      dc: dc,
      rect: RECT(
        left: client.right - self.scaled(88),
        top: y,
        right: client.right - inset,
        bottom: y + self.scaled(18)),
      color: WindowsDashboardPalette.primaryText,
      font: self.metricFont,
      format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE))
    let track = RECT(
      left: inset,
      top: y + self.scaled(23),
      right: client.right - inset,
      bottom: y + self.scaled(26))
    self.drawMeter(dc: dc, rect: track, usedPercent: usage.usedPercent)
    WindowsDashboardDrawing.text(
      usage.resetText,
      dc: dc,
      rect: RECT(
        left: inset,
        top: y + self.scaled(29),
        right: client.right - inset,
        bottom: y + self.scaled(47)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
  }

  private func drawSwitcher(dc: HDC?, client: RECT) {
    let contentState = self.beginContentClip(dc: dc, client: client)
    var y = self.scaled(Metrics.headerHeight) - self.scrollOffset
    let inset = self.scaled(Metrics.horizontalInset)
    for (index, row) in self.presentation.rows.enumerated() {
      let rect = RECT(
        left: 0,
        top: y,
        right: client.right,
        bottom: y + self.scaled(Metrics.switcherRowHeight))
      if rect.bottom > self.scaled(Metrics.headerHeight), rect.top < client.bottom {
        self.drawProviderLogo(
          dc: dc,
          provider: row.provider,
          rect: RECT(
            left: inset,
            top: rect.top + self.scaled(9),
            right: inset + self.scaled(18),
            bottom: rect.top + self.scaled(27)))
        WindowsDashboardDrawing.text(
          row.provider.displayName,
          dc: dc,
          rect: RECT(
            left: inset + self.scaled(28),
            top: rect.top,
            right: rect.right - self.scaled(48),
            bottom: rect.bottom),
          color: WindowsDashboardPalette.primaryText,
          font: self.bodyFont,
          format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        WindowsDashboardDrawing.text(
          row.statusText == "Available" ? "●" : "○",
          dc: dc,
          rect: RECT(
            left: rect.right - self.scaled(44),
            top: rect.top,
            right: rect.right - inset,
            bottom: rect.bottom),
          color: row.statusText == "Available"
            ? WindowsDashboardPalette.sageText : WindowsDashboardPalette.captionText,
          font: self.secondaryFont,
          format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE))
        if let hitRect = self.contentHitRect(rect, client: client) {
          self.hitTargets.append(HitTarget(rect: hitRect, action: .provider(index)))
        }
      }
      y = rect.bottom
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawHeader(dc: dc, client: client, title: "Providers")
    self.drawFooter(dc: dc, client: client, backAction: .back)
  }

  private func drawSettings(dc: HDC?, client: RECT) {
    let contentState = self.beginContentClip(dc: dc, client: client)
    let inset = self.scaled(Metrics.horizontalInset)
    var y = self.scaled(Metrics.headerHeight) - self.scrollOffset
    let usageModeRect = RECT(
      left: 0,
      top: y,
      right: client.right,
      bottom: y + self.scaled(Metrics.settingsGlobalHeight))
    self.drawGlobalToggle(
      dc: dc,
      client: client,
      rect: usageModeRect,
      isOn: self.configuration.usageBarsShowUsed,
      title: "Percentage used",
      subtitle: self.configuration.usageBarsShowUsed
        ? "Bars show quota consumed" : "Bars show quota left",
      action: .toggleUsageBarsShowUsed)
    y = usageModeRect.bottom
    let startupRect = RECT(
      left: 0,
      top: y,
      right: client.right,
      bottom: y + self.scaled(Metrics.settingsGlobalHeight))
    self.drawGlobalToggle(
      dc: dc,
      client: client,
      rect: startupRect,
      isOn: self.configuration.runAtStartup,
      title: "Run at startup",
      subtitle: "Start CodexBar when you sign in to Windows",
      action: .toggleRunAtStartup)
    y = startupRect.bottom
    let refreshRect = RECT(
      left: 0,
      top: y,
      right: client.right,
      bottom: y + self.scaled(Metrics.settingsGlobalHeight))
    self.drawRefreshInterval(dc: dc, client: client, rect: refreshRect)
    y = refreshRect.bottom
    let enabledProviders = self.configuration.enabledProviders
    let disabledProviders = WindowsProviderSettingsSearch.filteredDisabledProviders(
      in: self.configuration,
      query: self.disabledProviderSearchQuery)
    let sections = [
      (title: "ENABLED", providers: enabledProviders, showsSearch: false),
      (title: "DISABLED", providers: disabledProviders, showsSearch: true),
    ]
    for section in sections {
      let sectionRect = RECT(
        left: 0,
        top: y,
        right: client.right,
        bottom: y + self.scaled(Metrics.settingsSectionHeaderHeight))
      WindowsDashboardDrawing.line(
        dc: dc,
        fromX: inset,
        y: sectionRect.top + self.scaled(7),
        toX: client.right - inset,
        color: WindowsDashboardPalette.secondaryText)
      WindowsDashboardDrawing.text(
        section.title,
        dc: dc,
        rect: RECT(
          left: inset,
          top: sectionRect.top + self.scaled(10),
          right: client.right - inset,
          bottom: sectionRect.bottom),
        color: WindowsDashboardPalette.captionText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
      y = sectionRect.bottom

      if section.showsSearch {
        let searchRect = RECT(
          left: inset,
          top: y,
          right: client.right - inset,
          bottom: y + self.scaled(Metrics.settingsSearchHeight))
        WindowsDashboardDrawing.text(
          Self.searchIconGlyph,
          dc: dc,
          rect: RECT(
            left: searchRect.left,
            top: searchRect.top + self.scaled(4),
            right: searchRect.left + self.scaled(22),
            bottom: searchRect.top + self.scaled(34)),
          color: WindowsDashboardPalette.secondaryText,
          font: self.systemIconFont,
          format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        y = searchRect.bottom
        if section.providers.isEmpty {
          let emptyRect = RECT(
            left: inset,
            top: y,
            right: client.right - inset,
            bottom: y + self.scaled(Metrics.settingsRowHeight))
          WindowsDashboardDrawing.text(
            "No disabled providers found",
            dc: dc,
            rect: emptyRect,
            color: WindowsDashboardPalette.captionText,
            font: self.secondaryFont,
            format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
          y = emptyRect.bottom
        }
      }

      for provider in section.providers {
        let enabledPosition = enabledProviders.firstIndex(where: { $0.id == provider.id })
        let rect = RECT(
          left: 0,
          top: y,
          right: client.right,
          bottom: y + self.scaled(Metrics.settingsRowHeight))
        if rect.bottom > self.scaled(Metrics.headerHeight),
          rect.top < client.bottom - self.scaled(Metrics.footerHeight)
        {
          let isUnavailable =
            WindowsProviderConfigurationCatalog.unavailableInfo(for: provider.id) != nil
          let toggleRect = RECT(
            left: inset,
            top: rect.top + self.scaled(12),
            right: inset + self.scaled(18),
            bottom: rect.top + self.scaled(30))
          if !isUnavailable {
            WindowsDashboardDrawing.roundedRect(
              dc: dc,
              rect: toggleRect,
              radius: self.scaled(4),
              fill: provider.enabled
                ? WindowsDashboardPalette.sageSurface : WindowsDashboardPalette.surface,
              border: provider.enabled
                ? WindowsDashboardPalette.sage : WindowsDashboardPalette.border
            )
            if provider.enabled {
              WindowsDashboardDrawing.text(
                "✓",
                dc: dc,
                rect: toggleRect,
                color: WindowsDashboardPalette.sageText,
                font: self.secondaryFont,
                format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            }
          }
          let logoRect = RECT(
            left: toggleRect.right + self.scaled(8),
            top: rect.top + self.scaled(13),
            right: toggleRect.right + self.scaled(26),
            bottom: rect.top + self.scaled(31))
          self.drawProviderLogo(dc: dc, provider: provider.id, rect: logoRect)
          WindowsDashboardDrawing.text(
            provider.id.displayName,
            dc: dc,
            rect: RECT(
              left: logoRect.right + self.scaled(8),
              top: rect.top + self.scaled(4),
              right: rect.right - self.scaled(102),
              bottom: rect.top + self.scaled(23)),
            color: provider.enabled
              ? WindowsDashboardPalette.primaryText : WindowsDashboardPalette.secondaryText,
            font: self.bodyFont,
            format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
          WindowsDashboardDrawing.text(
            WindowsProviderSettingsPresentation.subtitle(
              configuration: provider,
              sourceText: self.presentation.rows.first(where: { $0.provider == provider.id })?
                .sourceText),
            dc: dc,
            rect: RECT(
              left: logoRect.right + self.scaled(8),
              top: rect.top + self.scaled(22),
              right: rect.right - self.scaled(102),
              bottom: rect.bottom - self.scaled(2)),
            color: WindowsDashboardPalette.captionText,
            font: self.secondaryFont,
            format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
          let topRect = RECT(
            left: rect.right - self.scaled(98),
            top: rect.top,
            right: rect.right - self.scaled(72),
            bottom: rect.bottom)
          let upRect = RECT(
            left: rect.right - self.scaled(72),
            top: rect.top,
            right: rect.right - self.scaled(46),
            bottom: rect.bottom)
          let downRect = RECT(
            left: rect.right - self.scaled(46),
            top: rect.top,
            right: rect.right - self.scaled(20),
            bottom: rect.bottom)
          WindowsDashboardDrawing.text(
            enabledPosition.map { $0 == 0 ? "" : "⇧" } ?? "",
            dc: dc,
            rect: topRect,
            color: WindowsDashboardPalette.secondaryText,
            font: self.secondaryFont,
            format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
          WindowsDashboardDrawing.text(
            enabledPosition.map { $0 == 0 ? "" : "↑" } ?? "",
            dc: dc,
            rect: upRect,
            color: WindowsDashboardPalette.secondaryText,
            font: self.secondaryFont,
            format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
          WindowsDashboardDrawing.text(
            enabledPosition.map { $0 + 1 == enabledProviders.count ? "" : "↓" } ?? "",
            dc: dc,
            rect: downRect,
            color: WindowsDashboardPalette.secondaryText,
            font: self.secondaryFont,
            format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
          WindowsDashboardDrawing.text(
            "›",
            dc: dc,
            rect: RECT(
              left: rect.right - self.scaled(20),
              top: rect.top,
              right: rect.right - self.scaled(6),
              bottom: rect.bottom),
            color: WindowsDashboardPalette.captionText,
            font: self.metricFont,
            format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
          if let hitRect = self.contentHitRect(rect, client: client) {
            self.hitTargets.append(
              HitTarget(rect: hitRect, action: .configureProvider(provider.id)))
          }
          if !isUnavailable {
            self.hitTargets.append(
              HitTarget(rect: toggleRect, action: .toggleProvider(provider.id)))
          }
          if let enabledPosition, enabledPosition > 0 {
            self.hitTargets.append(
              HitTarget(rect: topRect, action: .moveProviderToTop(provider.id)))
            self.hitTargets.append(HitTarget(rect: upRect, action: .moveProvider(provider.id, -1)))
          }
          if let enabledPosition, enabledPosition + 1 < enabledProviders.count {
            self.hitTargets.append(HitTarget(rect: downRect, action: .moveProvider(provider.id, 1)))
          }
        }
        y = rect.bottom
      }
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawHeader(dc: dc, client: client, title: "Settings")
    self.drawFooter(dc: dc, client: client, backAction: .back)
  }

  private func drawGlobalToggle(
    dc: HDC?,
    client: RECT,
    rect: RECT,
    isOn: Bool,
    title: String,
    subtitle: String,
    action: Action
  ) {
    guard rect.bottom > self.scaled(Metrics.headerHeight),
      rect.top < client.bottom - self.scaled(Metrics.footerHeight)
    else {
      return
    }
    let inset = self.scaled(Metrics.horizontalInset)
    let toggleRect = RECT(
      left: inset,
      top: rect.top + self.scaled(16),
      right: inset + self.scaled(18),
      bottom: rect.top + self.scaled(34))
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: toggleRect,
      radius: self.scaled(4),
      fill: isOn ? WindowsDashboardPalette.sageSurface : WindowsDashboardPalette.surface,
      border: isOn ? WindowsDashboardPalette.sage : WindowsDashboardPalette.border)
    if isOn {
      WindowsDashboardDrawing.text(
        "✓",
        dc: dc,
        rect: toggleRect,
        color: WindowsDashboardPalette.sageText,
        font: self.secondaryFont,
        format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
    }
    WindowsDashboardDrawing.text(
      title,
      dc: dc,
      rect: RECT(
        left: toggleRect.right + self.scaled(9),
        top: rect.top + self.scaled(6),
        right: rect.right - inset,
        bottom: rect.top + self.scaled(25)),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodyFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    WindowsDashboardDrawing.text(
      subtitle,
      dc: dc,
      rect: RECT(
        left: toggleRect.right + self.scaled(9),
        top: rect.top + self.scaled(24),
        right: rect.right - inset,
        bottom: rect.bottom - self.scaled(2)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    if let hitRect = self.contentHitRect(rect, client: client) {
      self.hitTargets.append(HitTarget(rect: hitRect, action: action))
    }
  }

  private func drawRefreshInterval(dc: HDC?, client: RECT, rect: RECT) {
    guard rect.bottom > self.scaled(Metrics.headerHeight),
      rect.top < client.bottom - self.scaled(Metrics.footerHeight)
    else {
      return
    }
    let inset = self.scaled(Metrics.horizontalInset)
    WindowsDashboardDrawing.text(
      "Refresh interval",
      dc: dc,
      rect: RECT(
        left: inset,
        top: rect.top + self.scaled(6),
        right: rect.right - self.scaled(104),
        bottom: rect.top + self.scaled(25)),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodyFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    WindowsDashboardDrawing.text(
      "Minutes between automatic refreshes",
      dc: dc,
      rect: RECT(
        left: inset,
        top: rect.top + self.scaled(24),
        right: rect.right - self.scaled(104),
        bottom: rect.bottom - self.scaled(2)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
    WindowsDashboardDrawing.text(
      "min",
      dc: dc,
      rect: RECT(
        left: rect.right - self.scaled(45),
        top: rect.top,
        right: rect.right - inset,
        bottom: rect.bottom),
      color: WindowsDashboardPalette.secondaryText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
  }

  private func drawProviderConfiguration(dc: HDC?, client: RECT, provider: WindowsProviderID) {
    guard let configuration = self.configuration.providers.first(where: { $0.id == provider })
    else {
      return
    }
    if let unavailable = WindowsProviderConfigurationCatalog.unavailableInfo(for: provider) {
      self.drawUnavailableProviderConfiguration(
        dc: dc,
        client: client,
        provider: provider,
        unavailable: unavailable)
      return
    }
    let contentState = self.beginContentClip(dc: dc, client: client)
    let inset = self.scaled(Metrics.horizontalInset)
    var y = self.scaled(Metrics.headerHeight + 12) - self.scrollOffset
    WindowsDashboardDrawing.text(
      "WSL distro",
      dc: dc,
      rect: RECT(left: inset, top: y, right: inset + self.scaled(82), bottom: y + self.scaled(28)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
    let draft = self.configuredProvider(provider) ?? configuration
    y += self.scaled(42)
    WindowsDashboardDrawing.text(
      "Credentials",
      dc: dc,
      rect: RECT(left: inset, top: y, right: inset + self.scaled(82), bottom: y + self.scaled(28)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
    y += self.scaled(42)
    y = self.drawCredentialHelp(dc: dc, client: client, top: y)
    if let capabilities = self.configurationCapabilities,
      capabilities.provider == provider
    {
      let fields = self.activeConfigurationFields
      if self.configurationCredentialSetDraftID == nil {
        let hintHeight = self.configurationAutomaticHintHeight(provider: provider)
        WindowsDashboardDrawing.text(
          WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: provider),
          dc: dc,
          rect: RECT(
            left: inset,
            top: y,
            right: client.right - inset,
            bottom: y + hintHeight - self.scaled(4)),
          color: WindowsDashboardPalette.captionText,
          font: self.secondaryFont,
          format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
      }
      for (index, field) in fields.enumerated() {
        y = self.configurationFieldRowTop(index: index)
        let showsSaved = self.showsSavedStatus(for: field)
        WindowsDashboardDrawing.text(
          field.label,
          dc: dc,
          rect: RECT(
            left: inset,
            top: y,
            right: showsSaved ? client.right - inset - self.scaled(54) : client.right - inset,
            bottom: y + self.scaled(18)),
          color: WindowsDashboardPalette.captionText,
          font: self.secondaryFont,
          format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if showsSaved {
          WindowsDashboardDrawing.text(
            "Saved",
            dc: dc,
            rect: RECT(
              left: client.right - inset - self.scaled(50),
              top: y,
              right: client.right - inset,
              bottom: y + self.scaled(18)),
            color: WindowsDashboardPalette.sageText,
            font: self.secondaryFont,
            format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        }
        if let guidance = field.guidance {
          WindowsDashboardDrawing.text(
            guidance,
            dc: dc,
            rect: RECT(
              left: inset,
              top: y + self.scaled(20),
              right: client.right - inset,
              bottom: y + self.scaled(20) + self.configurationFieldGuidanceHeight(field)),
            color: field.isBrowserCredential
              ? WindowsDashboardPalette.ochreText : WindowsDashboardPalette.captionText,
            font: self.secondaryFont,
            format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
        }
        if let validation = self.configurationFieldValidation(field) {
          let statusTop =
            y + self.configurationFieldInputTopOffset(field)
            + self.configurationFieldInputHeight(field) + self.scaled(3)
          WindowsDashboardDrawing.text(
            validation.text,
            dc: dc,
            rect: RECT(
              left: inset,
              top: statusTop,
              right: client.right - inset,
              bottom: statusTop + self.scaled(18)),
            color: validation.accepted
              ? WindowsDashboardPalette.sageText : WindowsDashboardPalette.clayText,
            font: self.secondaryFont,
            format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        }
      }
      y = self.configurationFieldRowTop(index: fields.count)
      if self.configurationCredentialSetDraftID == nil {
        y += self.configurationAutomaticHintHeight(provider: provider)
      }
    } else if WindowsProviderConfigurationCatalog.byProvider[provider] == nil {
      let hintHeight = self.configurationAutomaticHintHeight(provider: provider)
      WindowsDashboardDrawing.text(
        WindowsProviderConfigurationCatalog.automaticCredentialDescription(provider: provider),
        dc: dc,
        rect: RECT(
          left: inset,
          top: y,
          right: client.right - inset,
          bottom: y + hintHeight - self.scaled(4)),
        color: WindowsDashboardPalette.captionText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
      y += hintHeight
    }
    let error =
      self.configurationCapabilitiesError
      ?? self.configurationDraftValidationError
      ?? self.configurationErrorText(
        provider: provider,
        draft: draft)
    if let error {
      WindowsDashboardDrawing.text(
        error,
        dc: dc,
        rect: RECT(
          left: inset,
          top: y,
          right: client.right - inset,
          bottom: y + self.scaled(48)),
        color: WindowsDashboardPalette.clayText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawHeader(dc: dc, client: client, title: provider.displayName, provider: provider)
    let showsClearAction =
      self.configurationCanClearCredential
      && !self.hasDirtyProviderDraft
      && self.configurationPendingRequestID == nil
    self.drawFooter(
      dc: dc,
      client: client,
      backAction: .back,
      saveAction: showsClearAction
        ? .clearProvider(provider)
        : (self.hasDirtyProviderDraft && self.configurationPendingRequestID == nil
          ? .saveProvider(provider)
          : nil),
      saveLabel: showsClearAction ? "Clear" : "Apply")
  }

  private func drawUnavailableProviderConfiguration(
    dc: HDC?,
    client: RECT,
    provider: WindowsProviderID,
    unavailable: WindowsUnavailableProviderInfo
  ) {
    let contentState = self.beginContentClip(dc: dc, client: client)
    let inset = self.scaled(Metrics.horizontalInset)
    let top = self.scaled(Metrics.headerHeight + 20) - self.scrollOffset
    WindowsDashboardDrawing.text(
      "Not available on Windows",
      dc: dc,
      rect: RECT(
        left: inset,
        top: top,
        right: client.right - inset,
        bottom: top + self.scaled(24)),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodySemiboldFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
    WindowsDashboardDrawing.text(
      unavailable.explanation,
      dc: dc,
      rect: RECT(
        left: inset,
        top: top + self.scaled(34),
        right: client.right - inset,
        bottom: top + self.scaled(84)),
      color: WindowsDashboardPalette.secondaryText,
      font: self.bodyFont,
      format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
    if unavailable.resourceURL != nil {
      let linkRect = RECT(
        left: inset,
        top: top + self.scaled(96),
        right: client.right - inset,
        bottom: top + self.scaled(128))
      WindowsDashboardDrawing.roundedRect(
        dc: dc,
        rect: linkRect,
        radius: self.scaled(6),
        fill: WindowsDashboardPalette.surface,
        border: WindowsDashboardPalette.border)
      WindowsDashboardDrawing.text(
        "View upstream provider notes  ↗",
        dc: dc,
        rect: RECT(
          left: linkRect.left + self.scaled(10),
          top: linkRect.top,
          right: linkRect.right - self.scaled(10),
          bottom: linkRect.bottom),
        color: WindowsDashboardPalette.sageText,
        font: self.bodyFont,
        format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
      self.hitTargets.append(HitTarget(rect: linkRect, action: .openProviderResource(provider)))
    }
    self.endContentClip(dc: dc, state: contentState)
    self.drawHeader(dc: dc, client: client, title: provider.displayName, provider: provider)
    self.drawFooter(dc: dc, client: client, backAction: .back)
  }

  private func ensureConfigurationControls(_ configuration: WindowsProviderConfiguration) {
    guard WindowsProviderConfigurationCatalog.supportsConfigurationControls(for: configuration.id)
    else {
      return
    }
    guard self.configurationSourceControl == nil, let window = self.window else { return }
    self.configurationSourceDraft =
      configuration.sourceMode == .wsl
      ? configuration.wslDistro
      : nil
    self.configurationSourceControl = WindowsWideString.withPointer("COMBOBOX") { className in
      CreateWindowExW(
        0,
        className,
        nil,
        DWORD(WS_CHILD | WS_TABSTOP | WS_BORDER | WS_VSCROLL) | DWORD(CBS_DROPDOWNLIST),
        0,
        0,
        0,
        0,
        window,
        nil,
        self.instance,
        nil)
    }
    if let sourceControl = self.configurationSourceControl {
      WindowsVisualTheme.apply(toControl: sourceControl)
      Self.addComboItem("Automatic", to: sourceControl)
      for distribution in self.availableWSLDistributions {
        Self.addComboItem(distribution, to: sourceControl)
      }
      let selected =
        self.configurationSourceDraft.flatMap { selected in
          self.availableWSLDistributions.firstIndex(where: {
            $0.caseInsensitiveCompare(selected) == .orderedSame
          }).map { $0 + 1 }
        } ?? 0
      _ = SendMessageW(sourceControl, UINT(CB_SETCURSEL), WPARAM(selected), 0)
      if let bodyFont = self.bodyFont {
        _ = SendMessageW(sourceControl, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
      }
    }
    self.configurationCredentialControl = WindowsWideString.withPointer("COMBOBOX") { className in
      CreateWindowExW(
        0,
        className,
        nil,
        DWORD(WS_CHILD | WS_TABSTOP | WS_BORDER | WS_VSCROLL) | DWORD(CBS_DROPDOWNLIST),
        0,
        0,
        0,
        0,
        window,
        nil,
        self.instance,
        nil)
    }
    if let credentialControl = self.configurationCredentialControl {
      WindowsVisualTheme.apply(toControl: credentialControl)
      if let bodyFont = self.bodyFont {
        _ = SendMessageW(
          credentialControl,
          UINT(WM_SETFONT),
          WPARAM(UInt(bitPattern: bodyFont)),
          1)
      }
    }
    self.installProviderConfigurationSchema(provider: configuration.id)
  }

  private func installProviderConfigurationSchema(provider: WindowsProviderID) {
    let schema = WindowsProviderConfigurationCatalog.byProvider[provider]
    self.configurationCapabilities = schema
    self.configurationCapabilitiesError = nil
    self.configurationDraftValidationError = nil
    self.configurationStatus = nil
    self.configurationCanClearCredential = false
    self.configurationCredentialSetDraftID = nil
    self.configurationCredentialSelectionTouched = false
    self.configurationCredentialHelpExpanded = false
    self.populateCredentialMethods(schema)
    self.rebuildProviderFieldControls()
    if schema != nil, let configuration = self.configuredProvider(provider) {
      self.configurationPendingRequestID = WindowsTrayApplication.current?
        .requestProviderConfigurationStatus(provider: provider, configuration: configuration)
    }
  }

  private func populateCredentialMethods(_ schema: WindowsProviderConfigurationSchema?) {
    guard let control = self.configurationCredentialControl else { return }
    _ = SendMessageW(control, UINT(CB_RESETCONTENT), 0, 0)
    Self.addComboItem("Automatic", to: control)
    for set in schema?.manualCredentialSets ?? [] {
      Self.addComboItem(set.label, to: control)
    }
    self.updateCredentialMethodSelection()
  }

  private func updateCredentialMethodSelection() {
    guard let control = self.configurationCredentialControl else { return }
    let selection =
      self.configurationCredentialSetDraftID.flatMap { id in
        self.configurationCapabilities?.manualCredentialSets.firstIndex(where: { $0.id == id })
          .map { $0 + 1 }
      } ?? 0
    _ = SendMessageW(control, UINT(CB_SETCURSEL), WPARAM(selection), 0)
  }

  private var activeCredentialSet: WindowsProviderCredentialSet? {
    self.configurationCapabilities?.credentialSet(id: self.configurationCredentialSetDraftID)
  }

  private var activeConfigurationFields: [WindowsProviderConfigurationField] {
    self.activeCredentialSet?.fields ?? []
  }

  private func rebuildProviderFieldControls() {
    self.resetProviderFieldControls(clearCapabilities: false)
    guard let window = self.window else { return }
    for field in self.activeConfigurationFields {
      var style = DWORD(WS_CHILD | WS_TABSTOP | WS_BORDER)
      let usesSecureRichEdit = field.multiline && field.secret && windowsSecureRichEditAvailable
      style |=
        field.multiline && usesSecureRichEdit
        ? DWORD(ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL)
        : DWORD(ES_AUTOHSCROLL)
      if field.secret { style |= DWORD(ES_PASSWORD) }
      let className = usesSecureRichEdit ? "RICHEDIT50W" : "EDIT"
      let control = WindowsWideString.withPointer(className) { className in
        CreateWindowExW(0, className, nil, style, 0, 0, 0, 0, window, nil, self.instance, nil)
      }
      guard let control else { continue }
      WindowsVisualTheme.apply(toControl: control)
      if usesSecureRichEdit {
        _ = SendMessageW(control, UINT(EM_SETEVENTMASK), 0, LPARAM(Int(ENM_CHANGE)))
      }
      if field.secret {
        _ = SendMessageW(control, UINT(EM_SETPASSWORDCHAR), WPARAM(0x2022), 0)
      }
      _ = SendMessageW(control, UINT(EM_SETLIMITTEXT), 65_536, 0)
      if let bodyFont = self.bodyFont {
        _ = SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
      }
      WindowsWideString.withPointer(field.placeholder) { placeholder in
        _ = SendMessageW(control, UINT(EM_SETCUEBANNER), 0, LPARAM(Int(bitPattern: placeholder)))
      }
      if self.isConfigured(field) {
        if field.secret {
          WindowsWideString.withPointer(Self.storedSecretPlaceholder) { pointer in
            _ = SetWindowTextW(control, pointer)
          }
        } else if let value = self.configurationStatus?.companionValues[field.id] {
          WindowsWideString.withPointer(value) { pointer in _ = SetWindowTextW(control, pointer) }
        }
      }
      if usesSecureRichEdit {
        Self.applySecureRichEditPalette(to: control)
      }
      self.configurationFieldControls[field.id] = control
    }
  }

  private static func applySecureRichEditPalette(to control: HWND) {
    _ = SendMessageW(
      control,
      UINT(EM_SETBKGNDCOLOR),
      0,
      LPARAM(Int(WindowsDashboardPalette.surface)))

    var format = CHARFORMATW()
    format.cbSize = UINT(MemoryLayout<CHARFORMATW>.size)
    format.dwMask = DWORD(CFM_COLOR)
    format.crTextColor = WindowsDashboardPalette.primaryText
    for scope in [SCF_ALL, SCF_DEFAULT] {
      _ = withUnsafePointer(to: &format) { pointer in
        SendMessageW(
          control,
          UINT(EM_SETCHARFORMAT),
          WPARAM(scope),
          LPARAM(Int(bitPattern: pointer)))
      }
    }
  }

  private static func windowClassName(_ window: HWND?) -> String? {
    guard let window else { return nil }
    var buffer = [WCHAR](repeating: 0, count: 64)
    let length = GetClassNameW(window, &buffer, Int32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
  }

  private func resetProviderFieldControls(clearCapabilities: Bool = true) {
    for control in self.configurationFieldControls.values {
      WindowsWideString.withPointer("") { pointer in _ = SetWindowTextW(control, pointer) }
      _ = DestroyWindow(control)
    }
    self.configurationFieldControls.removeAll()
    if clearCapabilities { self.configurationCapabilities = nil }
  }

  private func ensureSettingsControls() {
    guard self.refreshIntervalControl == nil, let window = self.window else { return }
    self.refreshIntervalControl = WindowsWideString.withPointer("EDIT") { className in
      CreateWindowExW(
        0,
        className,
        nil,
        DWORD(WS_CHILD | WS_TABSTOP | WS_BORDER | ES_NUMBER | ES_CENTER | ES_AUTOHSCROLL),
        0,
        0,
        0,
        0,
        window,
        nil,
        self.instance,
        nil)
    }
    if let control = self.refreshIntervalControl {
      WindowsVisualTheme.apply(toControl: control)
      _ = SendMessageW(control, UINT(EM_SETLIMITTEXT), 4, 0)
      if let bodyFont = self.bodyFont {
        _ = SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
      }
      self.updateRefreshIntervalControlText()
    }
    self.disabledProviderSearchControl = WindowsWideString.withPointer("EDIT") { className in
      CreateWindowExW(
        0,
        className,
        nil,
        DWORD(WS_CHILD | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL),
        0,
        0,
        0,
        0,
        window,
        nil,
        self.instance,
        nil)
    }
    if let control = self.disabledProviderSearchControl {
      WindowsVisualTheme.apply(toControl: control)
      _ = SendMessageW(control, UINT(EM_SETLIMITTEXT), 120, 0)
      if let bodyFont = self.bodyFont {
        _ = SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
      }
      if !self.disabledProviderSearchQuery.isEmpty {
        WindowsWideString.setWindowText(control, self.disabledProviderSearchQuery)
      }
    }
  }

  private func updateRefreshIntervalControlText() {
    guard let control = self.refreshIntervalControl else { return }
    let value = String(self.configuration.refreshIntervalMinutes)
    guard Self.windowText(control) != value else { return }
    WindowsWideString.withPointer(value) { text in
      _ = SetWindowTextW(control, text)
    }
  }

  private func destroyConfigurationControls() {
    if let sourceControl = self.configurationSourceControl {
      _ = DestroyWindow(sourceControl)
    }
    if let refreshControl = self.refreshIntervalControl {
      _ = DestroyWindow(refreshControl)
    }
    if let searchControl = self.disabledProviderSearchControl {
      _ = DestroyWindow(searchControl)
    }
    if let credentialControl = self.configurationCredentialControl {
      _ = DestroyWindow(credentialControl)
    }
    self.resetProviderFieldControls()
    self.configurationSourceControl = nil
    self.configurationCredentialControl = nil
    self.refreshIntervalControl = nil
    self.disabledProviderSearchControl = nil
    self.configurationSourceDraft = nil
    self.configurationCredentialSetDraftID = nil
    self.configurationCredentialSelectionTouched = false
    self.configurationCredentialHelpExpanded = false
    self.configurationLastAppliedProvider = nil
    self.configurationCapabilitiesError = nil
    self.configurationDraftValidationError = nil
    self.configurationStatus = nil
    self.configurationCanClearCredential = false
    self.configurationPendingRequestID = nil
  }

  private func layoutConfigurationControls() {
    guard let window = self.window else { return }
    var client = RECT()
    guard GetClientRect(window, &client) else { return }
    let inset = self.scaled(Metrics.horizontalInset)
    let viewportTop = self.scaled(Metrics.headerHeight)
    let viewportBottom = client.bottom - self.scaled(Metrics.footerHeight)
    if let sourceControl = self.configurationSourceControl {
      guard case .configure = self.page else {
        _ = ShowWindow(sourceControl, SW_HIDE)
        return
      }
      let y = self.scaled(Metrics.headerHeight + 12) - self.scrollOffset
      let rect = RECT(
        left: inset + self.scaled(86),
        top: y,
        right: client.right - inset,
        bottom: y + self.scaled(28))
      if rect.top >= viewportTop, rect.bottom <= viewportBottom {
        _ = SetWindowPos(
          sourceControl,
          nil,
          rect.left,
          rect.top,
          rect.right - rect.left,
          self.scaled(150),
          UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
      } else {
        _ = ShowWindow(sourceControl, SW_HIDE)
      }
    }
    if let credentialControl = self.configurationCredentialControl {
      guard case .configure = self.page else {
        _ = ShowWindow(credentialControl, SW_HIDE)
        return
      }
      let y = self.scaled(Metrics.headerHeight + 54) - self.scrollOffset
      let rect = RECT(
        left: inset + self.scaled(86),
        top: y,
        right: client.right - inset,
        bottom: y + self.scaled(28))
      if rect.top >= viewportTop, rect.bottom <= viewportBottom {
        _ = SetWindowPos(
          credentialControl,
          nil,
          rect.left,
          rect.top,
          rect.right - rect.left,
          self.scaled(150),
          UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
      } else {
        _ = ShowWindow(credentialControl, SW_HIDE)
      }
    }
    if case .configure = self.page {
      for (index, field) in self.activeConfigurationFields.enumerated() {
        guard let control = self.configurationFieldControls[field.id] else { continue }
        let y = self.configurationFieldRowTop(index: index)
        let inputTop = y + self.configurationFieldInputTopOffset(field)
        let rect = RECT(
          left: inset,
          top: inputTop,
          right: client.right - inset,
          bottom: inputTop + self.configurationFieldInputHeight(field))
        if rect.top >= viewportTop, rect.bottom <= viewportBottom {
          _ = SetWindowPos(
            control,
            nil,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
        } else {
          _ = ShowWindow(control, SW_HIDE)
        }
      }
    } else {
      for control in self.configurationFieldControls.values { _ = ShowWindow(control, SW_HIDE) }
    }
    if let refreshControl = self.refreshIntervalControl {
      guard self.page == .settings else {
        _ = ShowWindow(refreshControl, SW_HIDE)
        return
      }
      let rowTop =
        self.scaled(Metrics.headerHeight + Metrics.settingsGlobalHeight * 2) - self.scrollOffset
      let rect = RECT(
        left: client.right - inset - self.scaled(88),
        top: rowTop + self.scaled(12),
        right: client.right - inset - self.scaled(49),
        bottom: rowTop + self.scaled(38))
      if rect.top >= viewportTop, rect.bottom <= viewportBottom {
        _ = SetWindowPos(
          refreshControl,
          nil,
          rect.left,
          rect.top,
          rect.right - rect.left,
          rect.bottom - rect.top,
          UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
      } else {
        _ = ShowWindow(refreshControl, SW_HIDE)
      }
    }
    if let searchControl = self.disabledProviderSearchControl {
      guard self.page == .settings else {
        _ = ShowWindow(searchControl, SW_HIDE)
        return
      }
      let rowTop =
        self.scaled(
          Metrics.headerHeight + Metrics.settingsGlobalHeight * 3
            + Metrics.settingsSectionHeaderHeight
            + Int32(self.configuration.enabledProviders.count) * Metrics.settingsRowHeight
            + Metrics.settingsSectionHeaderHeight) - self.scrollOffset
      let rect = RECT(
        left: inset + self.scaled(26),
        top: rowTop + self.scaled(4),
        right: client.right - inset,
        bottom: rowTop + self.scaled(34))
      if rect.top >= viewportTop, rect.bottom <= viewportBottom {
        _ = SetWindowPos(
          searchControl,
          nil,
          rect.left,
          rect.top,
          rect.right - rect.left,
          rect.bottom - rect.top,
          UINT(SWP_NOZORDER | SWP_SHOWWINDOW))
      } else {
        _ = ShowWindow(searchControl, SW_HIDE)
      }
    }
  }

  private func configurationFieldRowTop(index: Int) -> Int32 {
    let priorHeight = self.activeConfigurationFields.prefix(index).reduce(Int32(0)) {
      $0 + self.configurationFieldRowHeight($1)
    }
    return self.scaled(Metrics.headerHeight + 96) + self.configurationCredentialHelpHeight
      + priorHeight - self.scrollOffset
  }

  private func configurationAutomaticHintHeight(provider: WindowsProviderID) -> Int32 {
    let text = WindowsProviderConfigurationCatalog.automaticCredentialDescription(
      provider: provider)
    guard let window = self.window, let dc = GetDC(window) else { return self.scaled(38) }
    defer { _ = ReleaseDC(window, dc) }
    let oldFont = self.secondaryFont.map { SelectObject(dc, $0) }
    defer {
      if let oldFont { _ = SelectObject(dc, oldFont) }
    }
    var client = RECT()
    _ = GetClientRect(window, &client)
    var rect = RECT(
      left: 0,
      top: 0,
      right: max(1, client.right - self.scaled(Metrics.horizontalInset * 2)),
      bottom: 0)
    WindowsWideString.withPointer(text) { pointer in
      _ = DrawTextW(
        dc,
        pointer,
        -1,
        &rect,
        UINT(DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX))
    }
    return max(self.scaled(18), rect.bottom - rect.top) + self.scaled(6)
  }

  private var configurationCredentialHelpHeight: Int32 {
    guard let set = self.activeCredentialSet,
      !set.captureInstructions.isEmpty || set.securityNotice != nil
    else { return 0 }
    let expandedHeight =
      self.configurationCredentialHelpExpanded
      ? self.scaled(14 + Int32(set.captureInstructions.count) * 36)
      : 0
    let noticeHeight = set.securityNotice == nil ? 0 : self.scaled(38)
    return self.scaled(30) + expandedHeight + noticeHeight
  }

  private func drawCredentialHelp(dc: HDC?, client: RECT, top: Int32) -> Int32 {
    guard let set = self.activeCredentialSet,
      !set.captureInstructions.isEmpty || set.securityNotice != nil
    else { return top }
    let inset = self.scaled(Metrics.horizontalInset)
    let disclosure = RECT(
      left: inset,
      top: top,
      right: client.right - inset,
      bottom: top + self.scaled(28))
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: disclosure,
      radius: self.scaled(6),
      fill: WindowsDashboardPalette.surface,
      border: WindowsDashboardPalette.border)
    WindowsDashboardDrawing.text(
      self.configurationCredentialHelpExpanded ? "How to obtain this  ▲" : "How to obtain this  ▼",
      dc: dc,
      rect: RECT(
        left: disclosure.left + self.scaled(9),
        top: disclosure.top,
        right: disclosure.right - self.scaled(9),
        bottom: disclosure.bottom),
      color: WindowsDashboardPalette.secondaryText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
    if let hitRect = self.contentHitRect(disclosure, client: client) {
      self.hitTargets.append(HitTarget(rect: hitRect, action: .toggleCredentialHelp))
    }
    var y = disclosure.bottom
    if self.configurationCredentialHelpExpanded, !set.captureInstructions.isEmpty {
      y += self.scaled(8)
      for (index, instruction) in set.captureInstructions.enumerated() {
        WindowsDashboardDrawing.text(
          "\(index + 1). \(instruction)",
          dc: dc,
          rect: RECT(
            left: inset + self.scaled(4),
            top: y,
            right: client.right - inset,
            bottom: y + self.scaled(34)),
          color: WindowsDashboardPalette.captionText,
          font: self.secondaryFont,
          format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK))
        y += self.scaled(36)
      }
      y += self.scaled(6)
    }
    if let notice = set.securityNotice {
      WindowsDashboardDrawing.text(
        notice,
        dc: dc,
        rect: RECT(
          left: inset + self.scaled(4),
          top: y + self.scaled(4),
          right: client.right - inset,
          bottom: y + self.scaled(36)),
        color: WindowsDashboardPalette.ochreText,
        font: self.secondaryFont,
        format: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_END_ELLIPSIS))
      y += self.scaled(38)
    }
    return y
  }

  private func configurationFieldRowHeight(_ field: WindowsProviderConfigurationField) -> Int32 {
    self.configurationFieldInputTopOffset(field)
      + self.configurationFieldInputHeight(field)
      + self.scaled(16)
  }

  private func configurationFieldGuidanceHeight(_ field: WindowsProviderConfigurationField) -> Int32
  {
    guard let guidance = field.guidance else { return 0 }
    guard let window = self.window, let dc = GetDC(window) else { return self.scaled(18) }
    defer { _ = ReleaseDC(window, dc) }
    let oldFont = self.secondaryFont.map { SelectObject(dc, $0) }
    defer {
      if let oldFont { _ = SelectObject(dc, oldFont) }
    }
    var client = RECT()
    _ = GetClientRect(window, &client)
    var rect = RECT(
      left: 0,
      top: 0,
      right: max(1, client.right - self.scaled(Metrics.horizontalInset * 2)),
      bottom: 0)
    WindowsWideString.withPointer(guidance) { pointer in
      _ = DrawTextW(
        dc,
        pointer,
        -1,
        &rect,
        UINT(DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX))
    }
    return max(self.scaled(18), rect.bottom - rect.top)
  }

  private func configurationFieldInputTopOffset(_ field: WindowsProviderConfigurationField) -> Int32
  {
    guard field.guidance != nil else { return self.scaled(18) }
    return self.scaled(20) + self.configurationFieldGuidanceHeight(field) + self.scaled(7)
  }

  private func configurationFieldInputHeight(_ field: WindowsProviderConfigurationField) -> Int32 {
    self.scaled(field.multiline ? 68 : 26)
  }

  private func configurationFieldValidation(_ field: WindowsProviderConfigurationField)
    -> (text: String, accepted: Bool)?
  {
    guard let control = self.configurationFieldControls[field.id] else { return nil }
    let rawValue = Self.windowText(control).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawValue.isEmpty, rawValue != Self.storedSecretPlaceholder else { return nil }
    if let browserResult = field.displaySafeValidationResult(rawValue) {
      return (browserResult.summary, browserResult.isValid)
    }
    let accepted = field.accepts(rawValue)
    return (accepted ? "Accepted format" : "Check the required format", accepted)
  }

  private func isConfigured(_ field: WindowsProviderConfigurationField) -> Bool {
    self.configurationStatus?.credentialSetID == self.configurationCredentialSetDraftID
      && self.configurationStatus?.configuredFieldIDs.contains(field.id) == true
  }

  private func showsSavedStatus(for field: WindowsProviderConfigurationField) -> Bool {
    guard self.isConfigured(field),
      let control = self.configurationFieldControls[field.id]
    else { return false }
    let value = Self.windowText(control).trimmingCharacters(in: .whitespacesAndNewlines)
    if field.secret {
      return value.isEmpty || value == Self.storedSecretPlaceholder
    }
    return value == (self.configurationStatus?.companionValues[field.id] ?? "")
  }

  private func configuredProvider(_ provider: WindowsProviderID) -> WindowsProviderConfiguration? {
    guard var configuration = self.configuration.providers.first(where: { $0.id == provider })
    else {
      return nil
    }
    configuration.sourceMode = self.configurationSourceDraft == nil ? .automatic : .wsl
    configuration.wslDistro = self.configurationSourceDraft
    return configuration
  }

  private var hasDirtyProviderDraft: Bool {
    guard case .configure(let provider) = self.page,
      let saved = self.configuration.providers.first(where: { $0.id == provider }),
      let draft = self.configuredProvider(provider)
    else { return false }
    return WindowsProviderConfigurationPageState.hasUnsavedChanges(draft: draft, saved: saved)
      || self.hasDirtyCredentialDraft
  }

  private var hasDirtyCredentialDraft: Bool {
    if self.configurationCredentialSetDraftID != self.configurationStatus?.credentialSetID {
      return self.configurationCredentialSelectionTouched || self.configurationStatus != nil
    }
    for field in self.activeConfigurationFields {
      let value =
        self.configurationFieldControls[field.id]
        .map { Self.windowText($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
      if field.secret {
        if !value.isEmpty, value != Self.storedSecretPlaceholder { return true }
      } else if value != (self.configurationStatus?.companionValues[field.id] ?? "") {
        return true
      }
    }
    return false
  }

  private func providerCredentialValues() -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: self.activeConfigurationFields.compactMap { field in
        guard let control = self.configurationFieldControls[field.id] else { return nil }
        let value = Self.windowText(control).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == Self.storedSecretPlaceholder ? nil : (field.id, value)
      })
  }

  private func validatesCredentialDraft() -> Bool {
    guard let set = self.activeCredentialSet else {
      return self.configurationCredentialSetDraftID == nil
    }
    let values = self.providerCredentialValues()
    for field in set.fields {
      if let value = values[field.id] {
        guard field.accepts(value) else { return false }
      } else if field.required {
        let canRetain =
          field.secret
          && self.configurationStatus?.credentialSetID == set.id
          && self.configurationStatus?.configuredFieldIDs.contains(field.id) == true
        if !canRetain { return false }
      }
    }
    return true
  }

  private func configurationErrorText(
    provider: WindowsProviderID,
    draft: WindowsProviderConfiguration
  ) -> String? {
    guard let saved = self.configuration.providers.first(where: { $0.id == provider }) else {
      return nil
    }
    guard
      let error = WindowsProviderConfigurationPageState.errorText(
        provider: provider,
        lastAppliedProvider: self.configurationLastAppliedProvider,
        draft: draft,
        saved: saved,
        isRefreshing: self.presentation.isRefreshing,
        row: self.presentation.rows.first(where: { $0.provider == provider }))
    else { return nil }
    return "\(draft.sourceDisplayName): \(error)"
  }

  private static func addComboItem(_ value: String, to control: HWND) {
    WindowsWideString.withPointer(value) { pointer in
      _ = SendMessageW(control, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: pointer)))
    }
  }

  private func drawHeader(
    dc: HDC?,
    client: RECT,
    title: String,
    provider: WindowsProviderID? = nil
  ) {
    let height = self.scaled(Metrics.headerHeight)
    WindowsDashboardDrawing.line(
      dc: dc,
      fromX: 0,
      y: height - 1,
      toX: client.right,
      color: WindowsDashboardPalette.border)
    let inset = self.scaled(Metrics.horizontalInset)
    if let provider {
      let mark = RECT(
        left: inset,
        top: self.scaled(13),
        right: inset + self.scaled(18),
        bottom: self.scaled(31))
      self.drawProviderLogo(dc: dc, provider: provider, rect: mark)
    }
    WindowsDashboardDrawing.text(
      title,
      dc: dc,
      rect: RECT(
        left: provider == nil ? inset : inset + self.scaled(28),
        top: 0,
        right: client.right - inset,
        bottom: height),
      color: WindowsDashboardPalette.primaryText,
      font: self.bodySemiboldFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
  }

  private func drawFooter(
    dc: HDC?,
    client: RECT,
    backAction: Action? = nil,
    settingsAction: Action = .settings,
    saveAction: Action? = nil,
    saveLabel: String = "Apply"
  ) {
    let height = self.scaled(Metrics.footerHeight)
    let top = client.bottom - height
    let inset = self.scaled(Metrics.horizontalInset)
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: RECT(left: 0, top: top, right: client.right, bottom: client.bottom),
      radius: 0,
      fill: WindowsDashboardPalette.background)
    WindowsDashboardDrawing.line(
      dc: dc,
      fromX: 0,
      y: top,
      toX: client.right,
      color: WindowsDashboardPalette.border)
    if let backAction {
      let backRect = RECT(
        left: inset,
        top: top + self.scaled(5),
        right: inset + self.scaled(84),
        bottom: client.bottom - self.scaled(5))
      WindowsDashboardDrawing.roundedRect(
        dc: dc,
        rect: backRect,
        radius: self.scaled(6),
        fill: WindowsDashboardPalette.surface,
        border: WindowsDashboardPalette.border)
      WindowsDashboardDrawing.text(
        "‹  Back",
        dc: dc,
        rect: backRect,
        color: WindowsDashboardPalette.primaryText,
        font: self.bodySemiboldFont,
        format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
      self.hitTargets.append(
        HitTarget(
          rect: RECT(left: inset, top: top, right: inset + self.scaled(92), bottom: client.bottom),
          action: backAction))
    }
    if let saveAction {
      let saveRect = RECT(
        left: inset + self.scaled(92),
        top: top + self.scaled(5),
        right: inset + self.scaled(158),
        bottom: client.bottom - self.scaled(5))
      WindowsDashboardDrawing.roundedRect(
        dc: dc,
        rect: saveRect,
        radius: self.scaled(6),
        fill: WindowsDashboardPalette.sageSurface,
        border: WindowsDashboardPalette.sage)
      WindowsDashboardDrawing.text(
        saveLabel,
        dc: dc,
        rect: saveRect,
        color: WindowsDashboardPalette.sageText,
        font: self.bodySemiboldFont,
        format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
      self.hitTargets.append(HitTarget(rect: saveRect, action: saveAction))
    }
    let refreshRect = self.refreshIndicatorRect(client: client)
    if self.presentation.isRefreshing {
      WindowsDashboardDrawing.progressRing(
        dc: dc,
        rect: refreshRect,
        frame: self.refreshAnimationFrame,
        activeColor: WindowsDashboardPalette.secondaryText,
        inactiveColor: WindowsDashboardPalette.disabledText)
    } else {
      WindowsDashboardDrawing.text(
        Self.refreshIconGlyph,
        dc: dc,
        rect: refreshRect,
        color: WindowsDashboardPalette.secondaryText,
        font: self.systemIconFont,
        format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
    }
    self.hitTargets.append(HitTarget(rect: refreshRect, action: .refresh))
    let settingsRect = RECT(
      left: client.right - self.scaled(42),
      top: top,
      right: client.right - self.scaled(8),
      bottom: client.bottom)
    WindowsDashboardDrawing.text(
      Self.settingsIconGlyph,
      dc: dc,
      rect: settingsRect,
      color: WindowsDashboardPalette.secondaryText,
      font: self.systemIconFont,
      format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
    self.hitTargets.append(HitTarget(rect: settingsRect, action: settingsAction))
    let freshness =
      self.presentation.refreshedAt.map { self.freshnessText($0) }
      ?? (self.presentation.isRefreshing ? "Refreshing…" : "Not updated")
    WindowsDashboardDrawing.text(
      freshness,
      dc: dc,
      rect: RECT(
        left: backAction == nil
          ? inset
          : (saveAction == nil ? inset + self.scaled(98) : inset + self.scaled(166)),
        top: top,
        right: refreshRect.left - self.scaled(4),
        bottom: client.bottom),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
  }

  private func beginContentClip(dc: HDC?, client: RECT) -> Int32 {
    let state = SaveDC(dc)
    _ = IntersectClipRect(
      dc,
      0,
      self.currentHeaderHeight,
      client.right,
      client.bottom - self.scaled(Metrics.footerHeight))
    return state
  }

  private func endContentClip(dc: HDC?, state: Int32) {
    guard state != 0 else { return }
    _ = RestoreDC(dc, state)
  }

  private func drawLabelValue(dc: HDC?, client: RECT, y: Int32, label: String, value: String) {
    let inset = self.scaled(Metrics.horizontalInset)
    WindowsDashboardDrawing.text(
      label,
      dc: dc,
      rect: RECT(left: inset, top: y, right: inset + self.scaled(72), bottom: y + self.scaled(22)),
      color: WindowsDashboardPalette.captionText,
      font: self.secondaryFont,
      format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))
    WindowsDashboardDrawing.text(
      value,
      dc: dc,
      rect: RECT(
        left: inset + self.scaled(72),
        top: y,
        right: client.right - inset,
        bottom: y + self.scaled(22)),
      color: WindowsDashboardPalette.secondaryText,
      font: self.secondaryFont,
      format: UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
  }

  private func drawRule(dc: HDC?, client: RECT, y: Int32) {
    let inset = self.scaled(Metrics.horizontalInset)
    WindowsDashboardDrawing.line(
      dc: dc,
      fromX: inset,
      y: y,
      toX: client.right - inset,
      color: WindowsDashboardPalette.border)
  }

  private func drawMeter(dc: HDC?, rect: RECT, usedPercent: Double) {
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: rect,
      radius: self.scaled(2),
      fill: WindowsDashboardPalette.track)
    let clampedUsed = min(100, max(0, usedPercent))
    guard
      let geometry = WindowsMeterFillGeometry.make(
        trackLeft: rect.left,
        trackRight: rect.right,
        usedPercent: clampedUsed,
        showUsed: self.configuration.usageBarsShowUsed)
    else { return }
    let fill = RECT(left: geometry.left, top: rect.top, right: geometry.right, bottom: rect.bottom)
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: fill,
      radius: self.scaled(2),
      fill: WindowsDashboardPalette.progressColor(percent: clampedUsed))
  }

  private func drawProviderLogo(dc: HDC?, provider: WindowsProviderID, rect: RECT) {
    if self.providerLogoAtlas?.draw(provider: provider, dc: dc, rect: rect) == true { return }
    WindowsDashboardDrawing.roundedRect(
      dc: dc,
      rect: rect,
      radius: self.scaled(4),
      fill: WindowsDashboardPalette.selected,
      border: WindowsDashboardPalette.border)
    WindowsDashboardDrawing.text(
      Self.monogram(provider.displayName),
      dc: dc,
      rect: rect,
      color: WindowsDashboardPalette.sageText,
      font: self.secondaryFont,
      format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
  }

  private func activate(at point: POINT) {
    guard
      let target = self.hitTargets.reversed().first(where: { Self.contains($0.rect, point: point) })
    else {
      return
    }
    switch target.action {
    case .refresh:
      WindowsTrayApplication.current?.requestRefresh()
    case .settings:
      self.destroyConfigurationControls()
      self.page = .settings
      self.scrollOffset = 0
      self.ensureSettingsControls()
      self.resizeForCurrentPage()
    case .switcher:
      self.destroyConfigurationControls()
      self.page = .switcher
      self.scrollOffset = 0
      self.resizeForCurrentPage()
    case .back:
      let destination: Page =
        if case .configure = self.page {
          self.configurationReturnPage
        } else {
          .overview
        }
      self.destroyConfigurationControls()
      self.page = destination
      self.scrollOffset = 0
      if destination == .settings {
        self.ensureSettingsControls()
      }
      self.resizeForCurrentPage()
    case .provider(let index):
      self.destroyConfigurationControls()
      self.page = .provider(index)
      self.scrollOffset = 0
      self.resizeForCurrentPage()
    case .toggleUsageBarsShowUsed:
      WindowsTrayApplication.current?.toggleUsageBarsShowUsed()
    case .toggleRunAtStartup:
      WindowsTrayApplication.current?.toggleRunAtStartup()
    case .toggleProvider(let provider):
      WindowsTrayApplication.current?.toggleProvider(provider)
    case .moveProvider(let provider, let direction):
      WindowsTrayApplication.current?.moveProvider(provider, direction: direction)
    case .moveProviderToTop(let provider):
      WindowsTrayApplication.current?.moveProviderToTop(provider)
    case .configureProvider(let provider):
      self.configurationReturnPage = self.page
      self.destroyConfigurationControls()
      self.page = .configure(provider)
      self.scrollOffset = 0
      self.configurationLastAppliedProvider = nil
      if let configuration = self.configuration.providers.first(where: { $0.id == provider }) {
        self.ensureConfigurationControls(configuration)
      }
      self.resizeForCurrentPage()
      self.layoutConfigurationControls()
    case .saveProvider(let provider):
      guard let configuration = self.configuredProvider(provider) else { break }
      guard self.validatesCredentialDraft() else {
        self.configurationDraftValidationError =
          "Enter valid values for every required field before applying this credential method."
        break
      }
      if self.hasDirtyCredentialDraft {
        self.configurationCapabilitiesError = nil
        self.configurationDraftValidationError = nil
        self.configurationPendingRequestID = WindowsTrayApplication.current?
          .applyProviderConfiguration(
            provider: provider,
            configuration: configuration,
            credentialSetID: self.configurationCredentialSetDraftID,
            values: self.providerCredentialValues())
      } else if configuration != self.configuration.providers.first(where: { $0.id == provider }),
        WindowsTrayApplication.current?.updateProviderConfiguration(configuration) == true
      {
        self.configurationLastAppliedProvider = provider
      }
    case .clearProvider(let provider):
      guard let configuration = self.configuredProvider(provider) else { break }
      self.configurationCapabilitiesError = nil
      self.configurationDraftValidationError = nil
      self.configurationPendingRequestID = WindowsTrayApplication.current?
        .applyProviderConfiguration(
          provider: provider,
          configuration: configuration,
          credentialSetID: nil,
          values: [:])
    case .toggleCredentialHelp:
      self.configurationCredentialHelpExpanded.toggle()
      self.scrollOffset = min(self.scrollOffset, self.maximumScrollOffset())
      self.resizeForCurrentPage()
      self.layoutConfigurationControls()
    case .openProviderResource(let provider):
      self.openProviderResource(provider)
    }
    _ = InvalidateRect(self.window, nil, false)
  }

  private func handleKeyDown(wParam: WPARAM) -> LRESULT {
    if wParam == WPARAM(VK_ESCAPE) {
      if self.page == .overview {
        self.hide()
      } else {
        let destination: Page =
          if case .configure = self.page {
            self.configurationReturnPage
          } else {
            .overview
          }
        self.destroyConfigurationControls()
        self.page = destination
        self.scrollOffset = 0
        if destination == .settings {
          self.ensureSettingsControls()
        }
        self.resizeForCurrentPage()
        _ = InvalidateRect(self.window, nil, false)
      }
      return 0
    }
    if GetKeyState(Int32(VK_CONTROL)) < 0, wParam == WPARAM(0x52) {
      WindowsTrayApplication.current?.requestRefresh()
      return 0
    }
    return 0
  }

  private func scroll(delta: Int32) {
    let step = self.scaled(48)
    let proposed = self.scrollOffset - (delta > 0 ? step : -step)
    self.scrollOffset = min(self.maximumScrollOffset(), max(0, proposed))
    self.layoutConfigurationControls()
    _ = InvalidateRect(self.window, nil, false)
  }

  private func maximumScrollOffset() -> Int32 {
    guard let window = self.window else { return 0 }
    var client = RECT()
    guard GetClientRect(window, &client) else { return 0 }
    let viewport = client.bottom - self.currentHeaderHeight - self.scaled(Metrics.footerHeight)
    let content: Int32 =
      switch self.page {
      case .overview:
        Int32(self.presentation.rows.count) * self.scaled(Metrics.overviewRowHeight)
      case .switcher:
        Int32(self.presentation.rows.count) * self.scaled(Metrics.switcherRowHeight)
      case .provider(let index):
        self.providerContentHeight(index: index)
      case .settings:
        self.settingsContentHeight()
      case .configure:
        self.configurationContentHeight()
      }
    return max(0, content - viewport)
  }

  private func resizeForCurrentPage() {
    guard self.isVisible, let window = self.window else { return }
    let size = self.desiredWindowSize()
    var rect = RECT()
    guard GetWindowRect(window, &rect) else { return }
    let monitor = MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST))
    var info = MONITORINFO()
    info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    let workArea = GetMonitorInfoW(monitor, &info) ? info.rcWork : rect
    let gap = self.scaled(8)
    let x = min(max(workArea.left + gap, rect.left), workArea.right - size.cx - gap)
    let y = min(
      max(workArea.top + gap, rect.bottom - size.cy),
      workArea.bottom - size.cy - gap)
    _ = SetWindowPos(
      window,
      nil,
      x,
      y,
      size.cx,
      size.cy,
      UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    self.layoutConfigurationControls()
  }

  private func desiredWindowSize() -> SIZE {
    let contentHeight: Int32 =
      switch self.page {
      case .overview:
        Int32(self.presentation.rows.count) * self.scaled(Metrics.overviewRowHeight)
      case .switcher:
        Int32(self.presentation.rows.count) * self.scaled(Metrics.switcherRowHeight)
      case .provider(let index):
        self.providerContentHeight(index: index)
      case .settings:
        self.settingsContentHeight()
      case .configure:
        self.configurationContentHeight()
      }
    let fullHeight = contentHeight + self.currentHeaderHeight + self.scaled(Metrics.footerHeight)
    return SIZE(
      cx: self.scaled(Metrics.width),
      cy: min(
        self.scaled(Metrics.maximumHeight), max(self.scaled(Metrics.minimumHeight), fullHeight)))
  }

  private func providerContentHeight(index: Int) -> Int32 {
    guard index < self.presentation.rows.count else { return self.scaled(120) }
    let row = self.presentation.rows[index]
    var value: Int32 = 24 + Int32(row.windows.count) * 52 + 48
    if !row.planText.isEmpty || !row.accountText.isEmpty { value += 28 }
    if !row.balanceText.isEmpty { value += 44 }
    if !row.errorText.isEmpty { value += 48 }
    return self.scaled(value)
  }

  private func settingsContentHeight() -> Int32 {
    let disabledCount = max(
      1,
      WindowsProviderSettingsSearch.filteredDisabledProviders(
        in: self.configuration,
        query: self.disabledProviderSearchQuery
      ).count)
    return self.scaled(
      Metrics.settingsGlobalHeight * 3 + Metrics.settingsSectionHeaderHeight * 2
        + Metrics.settingsSearchHeight)
      + Int32(self.configuration.enabledProviders.count + disabledCount)
      * self.scaled(Metrics.settingsRowHeight)
  }

  private func configurationContentHeight() -> Int32 {
    guard case .configure(let provider) = self.page else { return self.scaled(110) }
    if !WindowsProviderConfigurationCatalog.supportsConfigurationControls(for: provider) {
      return self.scaled(160)
    }
    let draft = self.configuredProvider(provider)
    let errorHeight: Int32 =
      if self.configurationCapabilitiesError != nil || self.configurationDraftValidationError != nil
        || (draft.map {
          self.configurationErrorText(provider: provider, draft: $0) != nil
        } ?? false)
      {
        46
      } else {
        0
      }
    let fieldsHeight = self.activeConfigurationFields.reduce(Int32(0)) {
      $0 + self.configurationFieldRowHeight($1)
    }
    let loadingHeight: Int32 = self.configurationPendingRequestID == nil ? 0 : 38
    let automaticHintHeight: Int32 =
      self.configurationCredentialSetDraftID == nil
      ? self.configurationAutomaticHintHeight(provider: provider)
      : 0
    return self.scaled(96 + loadingHeight + errorHeight)
      + self.configurationCredentialHelpHeight
      + fieldsHeight
      + automaticHintHeight
  }

  private func anchoredOrigin(size: SIZE) -> POINT {
    var cursor = POINT()
    _ = GetCursorPos(&cursor)
    let monitor = MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST))
    var info = MONITORINFO()
    info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    let workArea: RECT
    if GetMonitorInfoW(monitor, &info) {
      workArea = info.rcWork
    } else {
      workArea = RECT(
        left: 0,
        top: 0,
        right: GetSystemMetrics(Int32(SM_CXSCREEN)),
        bottom: GetSystemMetrics(Int32(SM_CYSCREEN)))
    }
    let gap = self.scaled(8)
    let preferredX = cursor.x - size.cx + self.scaled(24)
    let x = min(max(workArea.left + gap, preferredX), workArea.right - size.cx - gap)
    let preferredY = cursor.y - size.cy - gap
    let y = min(max(workArea.top + gap, preferredY), workArea.bottom - size.cy - gap)
    return POINT(x: x, y: y)
  }

  private func handleDPIChanged(lParam: LPARAM) {
    guard let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam)), let window = self.window
    else {
      return
    }
    self.dpi = GetDpiForWindow(window)
    self.releaseFonts()
    self.createFonts()
    if let bodyFont = self.bodyFont, let sourceControl = self.configurationSourceControl {
      _ = SendMessageW(sourceControl, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
    }
    if let bodyFont = self.bodyFont, let credentialControl = self.configurationCredentialControl {
      _ = SendMessageW(
        credentialControl,
        UINT(WM_SETFONT),
        WPARAM(UInt(bitPattern: bodyFont)),
        1)
    }
    if let bodyFont = self.bodyFont, let refreshControl = self.refreshIntervalControl {
      _ = SendMessageW(refreshControl, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
    }
    if let bodyFont = self.bodyFont, let searchControl = self.disabledProviderSearchControl {
      _ = SendMessageW(searchControl, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: bodyFont)), 1)
    }
    let rect = suggested.pointee
    _ = SetWindowPos(
      window,
      nil,
      rect.left,
      rect.top,
      rect.right - rect.left,
      rect.bottom - rect.top,
      UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    self.layoutConfigurationControls()
    _ = InvalidateRect(window, nil, false)
  }

  private func registerWindowClass() -> Bool {
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.style = 0
    windowClass.lpfnWndProc = codexBarPopupWindowProcedure
    windowClass.hInstance = self.instance
    windowClass.hCursor = LoadCursorW(nil, LPCWSTR(bitPattern: 32512))
    return WindowsWideString.withPointer(codexBarPopupClassName) { className in
      windowClass.lpszClassName = className
      let result = RegisterClassExW(&windowClass)
      return result != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS)
    }
  }

  private func createFonts() {
    var base = LOGFONTW()
    WindowsWideString.copy("Segoe UI Variable Text", to: &base.lfFaceName.0, capacity: 32)
    base.lfQuality = BYTE(CLEARTYPE_QUALITY)
    self.bodyFont = self.makeFont(base: base, pixels: 12, weight: Int32(FW_NORMAL))
    self.bodySemiboldFont = self.makeFont(base: base, pixels: 13, weight: Int32(FW_SEMIBOLD))
    self.metricFont = self.makeFont(base: base, pixels: 14, weight: Int32(FW_SEMIBOLD))
    self.secondaryFont = self.makeFont(base: base, pixels: 11, weight: Int32(FW_NORMAL))
    let iconFace = self.preferredSystemIconFace()
    self.systemIconFont = self.makeSystemIconFont(face: iconFace, pixels: 16, rotation: 0)
  }

  private func makeFont(base: LOGFONTW, pixels: Int32, weight: Int32) -> HFONT? {
    var font = base
    font.lfHeight = -MulDiv(pixels, Int32(self.dpi), 96)
    font.lfWeight = weight
    return CreateFontIndirectW(&font)
  }

  private func releaseFonts() {
    for font in [
      self.bodyFont, self.bodySemiboldFont, self.metricFont, self.secondaryFont,
      self.systemIconFont,
    ] {
      if let font { _ = DeleteObject(font) }
    }
    self.bodyFont = nil
    self.bodySemiboldFont = nil
    self.metricFont = nil
    self.secondaryFont = nil
    self.systemIconFont = nil
  }

  private func preferredSystemIconFace() -> String {
    let fluent = "Segoe Fluent Icons"
    guard let probe = self.makeSystemIconFont(face: fluent, pixels: 16, rotation: 0) else {
      return "Segoe MDL2 Assets"
    }
    defer { _ = DeleteObject(probe) }
    return Self.realizedFontFace(probe)?.caseInsensitiveCompare(fluent) == .orderedSame
      ? fluent
      : "Segoe MDL2 Assets"
  }

  private func makeSystemIconFont(face: String, pixels: Int32, rotation: Int32) -> HFONT? {
    var font = LOGFONTW()
    WindowsWideString.copy(face, to: &font.lfFaceName.0, capacity: 32)
    font.lfQuality = BYTE(CLEARTYPE_QUALITY)
    font.lfEscapement = rotation
    font.lfOrientation = rotation
    return self.makeFont(base: font, pixels: pixels, weight: Int32(FW_NORMAL))
  }

  private static func realizedFontFace(_ font: HFONT) -> String? {
    guard let dc = CreateCompatibleDC(nil) else { return nil }
    defer { _ = DeleteDC(dc) }
    let oldFont = SelectObject(dc, font)
    defer {
      if let oldFont { _ = SelectObject(dc, oldFont) }
    }
    var buffer = [WCHAR](repeating: 0, count: 64)
    let count = buffer.withUnsafeMutableBufferPointer { pointer in
      GetTextFaceW(dc, Int32(pointer.count), pointer.baseAddress)
    }
    guard count > 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? min(Int(count), buffer.count)
    return String(decoding: buffer[..<end], as: UTF16.self)
  }

  private func openProviderResource(_ provider: WindowsProviderID) {
    guard
      let rawURL = WindowsProviderConfigurationCatalog.unavailableInfo(for: provider)?.resourceURL,
      let components = URLComponents(string: rawURL),
      components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
      components.host?.caseInsensitiveCompare("github.com") == .orderedSame,
      components.user == nil,
      components.password == nil
    else { return }
    WindowsWideString.withPointer("open") { operation in
      WindowsWideString.withPointer(rawURL) { file in
        _ = ShellExecuteW(self.window, operation, file, nil, nil, Int32(SW_SHOWNORMAL))
      }
    }
  }

  private func freshnessText(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "Updated now" }
    if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
    if seconds < 86400 { return "Updated \(seconds / 3600)h ago" }
    return "Updated \(seconds / 86400)d ago"
  }

  private func updateRefreshAnimationTimer() {
    guard let window = self.window else { return }
    if self.presentation.isRefreshing {
      _ = SetTimer(
        window,
        Self.refreshAnimationTimerID,
        WindowsSpinnerPresentation.frameIntervalMilliseconds,
        nil)
    } else {
      _ = KillTimer(window, Self.refreshAnimationTimerID)
      self.refreshAnimationFrame = 0
    }
  }

  private func refreshIndicatorRect(client: RECT) -> RECT {
    let top = client.bottom - self.scaled(Metrics.footerHeight)
    return RECT(
      left: client.right - self.scaled(76),
      top: top,
      right: client.right - self.scaled(42),
      bottom: client.bottom)
  }

  private var currentHeaderHeight: Int32 {
    self.page == .overview ? 0 : self.scaled(Metrics.headerHeight)
  }

  private var isProviderConfigurationPage: Bool {
    if case .configure = self.page { return true }
    return false
  }

  private func contentHitRect(_ rect: RECT, client: RECT) -> RECT? {
    let clipped = RECT(
      left: max(0, rect.left),
      top: max(self.currentHeaderHeight, rect.top),
      right: min(client.right, rect.right),
      bottom: min(client.bottom - self.scaled(Metrics.footerHeight), rect.bottom))
    return clipped.left < clipped.right && clipped.top < clipped.bottom ? clipped : nil
  }

  private func scaled(_ value: Int32) -> Int32 {
    MulDiv(value, Int32(self.dpi), 96)
  }

  private static func point(from lParam: LPARAM) -> POINT {
    let raw = UInt32(truncatingIfNeeded: lParam)
    return POINT(
      x: Int32(Int16(bitPattern: UInt16(raw & 0xFFFF))),
      y: Int32(Int16(bitPattern: UInt16((raw >> 16) & 0xFFFF))))
  }

  private static func wheelDelta(from wParam: WPARAM) -> Int32 {
    let raw = UInt32(truncatingIfNeeded: wParam)
    return Int32(Int16(bitPattern: UInt16((raw >> 16) & 0xFFFF)))
  }

  private static func windowText(_ window: HWND) -> String {
    let length = Int(GetWindowTextLengthW(window))
    var buffer = [WCHAR](repeating: 0, count: max(1, length + 1))
    let copied = buffer.withUnsafeMutableBufferPointer {
      GetWindowTextW(window, $0.baseAddress, Int32($0.count))
    }
    return String(decoding: buffer.prefix(Int(max(0, copied))), as: UTF16.self)
  }

  private static func monogram(_ name: String) -> String {
    name.first.map { String($0).uppercased() } ?? "•"
  }

  private static func contains(_ rect: RECT, point: POINT) -> Bool {
    point.x >= rect.left && point.x < rect.right && point.y >= rect.top && point.y < rect.bottom
  }
}
