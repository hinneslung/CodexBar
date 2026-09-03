import Foundation
import WinSDK

/// An HWND is an immutable process-local token. The box makes that value safe to capture without
/// reconstructing an optional WinSDK pointer from integer bits on a background executor.

private let codexBarMessageWindowClassName = "CodexBarMessageWindow"
private func codexBarMessageWindowProcedure(
  _ window: HWND?,
  _ message: UINT,
  _ wParam: WPARAM,
  _ lParam: LPARAM
) -> LRESULT {
  WindowsTrayApplication.current?.handleMessageWindowMessage(
    window: window,
    message: message,
    wParam: wParam,
    lParam: lParam) ?? DefWindowProcW(window, message, wParam, lParam)
}
private final class WindowsRefreshResultBox: @unchecked Sendable {
  let snapshots: [WindowsProviderSnapshot]
  let refreshedAt: Date
  let generation: UInt64

  init(snapshots: [WindowsProviderSnapshot], refreshedAt: Date, generation: UInt64) {
    self.snapshots = snapshots
    self.refreshedAt = refreshedAt
    self.generation = generation
  }
}
private final class WindowsRefreshResultStore: @unchecked Sendable {
  private let lock = NSLock()
  private var result: WindowsRefreshResultBox?

  func publish(_ result: WindowsRefreshResultBox) {
    self.lock.lock()
    self.result = result
    self.lock.unlock()
  }

  func take() -> WindowsRefreshResultBox? {
    self.lock.lock()
    defer { self.lock.unlock() }
    let result = self.result
    self.result = nil
    return result
  }
}
private struct WindowsConfigurationTaskResult: Sendable {
  let requestID: Foundation.UUID
  let provider: WindowsProviderID
  let status: WindowsUpstreamConfigurationStatus?
  let didApply: Bool
  let appliedConfiguration: WindowsProviderConfiguration?
  let safeErrorText: String?
  let canClearCredential: Bool
}
private final class WindowsConfigurationTaskResultStore: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [WindowsConfigurationTaskResult] = []

  func publish(_ result: WindowsConfigurationTaskResult) {
    self.lock.lock()
    self.results.append(result)
    self.lock.unlock()
  }

  func take() -> WindowsConfigurationTaskResult? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.results.isEmpty ? nil : self.results.removeFirst()
  }
}
private final class WindowsWindowHandleBox: @unchecked Sendable {
  let value: HWND?

  init(_ value: HWND?) {
    self.value = value
  }
}
final class WindowsTrayApplication {
  nonisolated(unsafe) static var current: WindowsTrayApplication?

  private enum Command: UInt16 {
    case refresh = 1001
    case popup = 1002
    case about = 1003
    case quit = 1004
  }

  private static let trayIconID: UINT = 1
  private static let refreshTimerID: UINT_PTR = 1
  private static let refreshCompletionTimerID: UINT_PTR = 2
  private static let refreshCompletionPollMilliseconds: UINT = 100
  private static let trayCallbackMessage = UINT(WM_APP + 1)
  private static let refreshCompletedMessage = UINT(WM_APP + 2)
  private static let trayAddCompletedMessage = UINT(WM_APP + 3)
  private static let configurationTaskCompletedMessage = UINT(WM_APP + 4)
  static let addTrayIconFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP)
  static let updateTrayTooltipFlags = UINT(NIF_TIP | NIF_SHOWTIP)

  private let instance: HINSTANCE?
  private let dataSource: AnyWindowsProviderDataSource
  private let configurationStore: WindowsConfigurationStore?
  private let credentialRouteResolver: WindowsProviderCredentialRouteResolver
  private let popup: WindowsPopupWindow
  private let applicationIcon: WindowsApplicationIcon
  private let showPopupOnStart: Bool
  private let refreshResultStore = WindowsRefreshResultStore()
  private let configurationTaskResultStore = WindowsConfigurationTaskResultStore()
  private let providerConfigurationClient: WindowsProviderConfigurationClient
  private var messageWindow: HWND?
  private var taskbarCreatedMessage: UINT = 0
  private var configuration: WindowsAppConfiguration
  private var presentation: WindowsDashboardPresentation
  private var lastSuccessfulSnapshots: [WindowsProviderID: WindowsProviderSnapshot] = [:]
  private var lastPublishedSnapshots: [WindowsProviderID: WindowsProviderSnapshot] = [:]
  private var refreshGate = WindowsRefreshGate()
  private var refreshGeneration: UInt64 = 0
  private var refreshTask: Task<Void, Never>?
  private var credentialMutationRequestIDs = Set<Foundation.UUID>()
  private var trayIconAdded = false
  private var isAddingTrayIcon = false
  private var trayActivationGate = WindowsTrayActivationGate()

  init(
    dataSource: AnyWindowsProviderDataSource,
    configurationStore: WindowsConfigurationStore? = nil,
    credentialRouteResolver: WindowsProviderCredentialRouteResolver = .init(
      credentialVault: nil),
    providerConfigurationClient: WindowsProviderConfigurationClient =
      WindowsProviderConfigurationClient(),
    showPopupOnStart: Bool = ProcessInfo.processInfo.environment["CODEXBAR_WINDOWS_SHOW_ON_START"]
      == "1"
  ) {
    self.instance = GetModuleHandleW(nil)
    self.dataSource = dataSource
    self.configurationStore = configurationStore
    self.credentialRouteResolver = credentialRouteResolver
    self.providerConfigurationClient = providerConfigurationClient
    self.configuration = (try? configurationStore?.load()) ?? .defaults
    self.presentation = .loading(providers: self.configuration.enabledProviderIDs)
    self.popup = WindowsPopupWindow(instance: self.instance)
    self.applicationIcon = WindowsApplicationIcon.load()
    self.showPopupOnStart = showPopupOnStart
  }

  func run() -> Int32 {
    Self.current = self
    defer { Self.current = nil }

    guard self.createMessageWindow() else {
      self.showStartupError("CodexBar could not create its Windows message window.")
      return 1
    }
    defer { self.releaseWindowsResources() }
    guard self.popup.create() else {
      self.showStartupError("CodexBar could not create its notification-area popup.")
      return 1
    }
    self.applicationIcon.apply(to: self.popup.window)
    WindowsVisualTheme.apply(to: self.popup.window)

    self.taskbarCreatedMessage = WindowsWideString.withPointer("TaskbarCreated") { pointer in
      RegisterWindowMessageW(pointer)
    }
    self.requestAddTrayIcon()
    guard self.installRefreshTimer(minutes: self.configuration.refreshIntervalMinutes) else {
      self.showStartupError("CodexBar could not start its refresh timer.")
      return 1
    }
    if self.configuration.runAtStartup {
      WindowsStartupTask.repairIfEnabled()
    }
    self.popup.update(self.presentation)
    self.popup.updateConfiguration(self.configuration)
    self.requestRefresh()
    if self.showPopupOnStart {
      self.popup.showAnchored()
    }

    var message = MSG()
    while true {
      SetLastError(0)
      if !GetMessageW(&message, nil, 0, 0) {
        return GetLastError() == 0 ? Int32(message.wParam) : 1
      }
      if self.popup.handleDialogMessage(&message) {
        continue
      }
      _ = TranslateMessage(&message)
      _ = DispatchMessageW(&message)
    }
  }

  func handleMessageWindowMessage(
    window: HWND?,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM
  ) -> LRESULT {
    if self.taskbarCreatedMessage != 0, message == self.taskbarCreatedMessage {
      self.trayIconAdded = false
      self.isAddingTrayIcon = false
      self.requestAddTrayIcon()
      return 0
    }

    switch message {
    case Self.trayCallbackMessage:
      return self.handleTrayCallback(lParam: lParam)
    case UINT(WM_COMMAND):
      self.handleCommand(UInt16(truncatingIfNeeded: wParam))
      return 0
    case UINT(WM_TIMER):
      if UINT_PTR(wParam) == Self.refreshCompletionTimerID {
        self.consumeRefreshResult()
      } else if UINT_PTR(wParam) == Self.refreshTimerID {
        self.requestRefresh()
      }
      return 0
    case Self.refreshCompletedMessage:
      self.consumeRefreshResult()
      return 0
    case Self.trayAddCompletedMessage:
      self.isAddingTrayIcon = false
      self.trayIconAdded = wParam != 0
      if !self.trayIconAdded {
        self.showStartupError("CodexBar could not add its notification-area icon.")
      }
      return 0
    case Self.configurationTaskCompletedMessage:
      self.consumeConfigurationTaskResult()
      return 0
    case UINT(WM_DESTROY):
      self.removeTrayIcon()
      PostQuitMessage(0)
      return 0
    default:
      return DefWindowProcW(window, message, wParam, lParam)
    }
  }

  func handlePopupMessage(
    window: HWND?,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM
  ) -> LRESULT {
    self.popup.handleMessage(window: window, message: message, wParam: wParam, lParam: lParam)
  }

  private func createMessageWindow() -> Bool {
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.lpfnWndProc = codexBarMessageWindowProcedure
    windowClass.hInstance = self.instance

    let registered = WindowsWideString.withPointer(codexBarMessageWindowClassName) { className in
      windowClass.lpszClassName = className
      let result = RegisterClassExW(&windowClass)
      return result != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS)
    }
    guard registered else { return false }

    self.messageWindow = WindowsWideString.withPointer(codexBarMessageWindowClassName) {
      className in
      WindowsWideString.withPointer("CodexBar") { title in
        CreateWindowExW(
          0,
          className,
          title,
          0,
          0,
          0,
          0,
          0,
          nil,
          nil,
          self.instance,
          nil)
      }
    }
    return self.messageWindow != nil
  }

  private func requestAddTrayIcon() {
    guard !self.trayIconAdded, !self.isAddingTrayIcon, let messageWindow = self.messageWindow else {
      return
    }
    self.isAddingTrayIcon = true
    let window = WindowsWindowHandleBox(messageWindow)
    let tooltip = self.presentation.trayTooltip(showUsed: self.configuration.usageBarsShowUsed)
    let applicationIcon = self.applicationIcon
    Thread.detachNewThread { @Sendable [applicationIcon, tooltip, window] in
      let added = Self.addTrayIcon(
        window: window.value,
        tooltip: tooltip,
        icon: applicationIcon.small)
      _ = PostMessageW(
        window.value,
        Self.trayAddCompletedMessage,
        WPARAM(added ? 1 : 0),
        0)
    }
  }

  private static func addTrayIcon(window: HWND?, tooltip: String, icon: HICON?) -> Bool {
    guard let window else { return false }
    var iconData = NOTIFYICONDATAW()
    iconData.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    iconData.hWnd = window
    iconData.uID = Self.trayIconID
    iconData.uFlags = Self.addTrayIconFlags
    iconData.uCallbackMessage = Self.trayCallbackMessage
    iconData.hIcon = icon
    let tooltipCapacity = MemoryLayout.size(ofValue: iconData.szTip) / MemoryLayout<WCHAR>.size
    withUnsafeMutablePointer(to: &iconData.szTip) { tuplePointer in
      tuplePointer.withMemoryRebound(to: WCHAR.self, capacity: tooltipCapacity) { buffer in
        WindowsWideString.copy(tooltip, to: buffer, capacity: tooltipCapacity)
      }
    }
    guard Shell_NotifyIconW(DWORD(NIM_ADD), &iconData) else { return false }
    iconData.uVersion = UINT(NOTIFYICON_VERSION_4)
    return Shell_NotifyIconW(DWORD(NIM_SETVERSION), &iconData)
  }

  private func updateTrayTooltip() {
    guard self.trayIconAdded, let messageWindow = self.messageWindow else { return }
    var iconData = NOTIFYICONDATAW()
    iconData.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    iconData.hWnd = messageWindow
    iconData.uID = Self.trayIconID
    iconData.uFlags = Self.updateTrayTooltipFlags
    let tooltipCapacity = MemoryLayout.size(ofValue: iconData.szTip) / MemoryLayout<WCHAR>.size
    withUnsafeMutablePointer(to: &iconData.szTip) { tuplePointer in
      tuplePointer.withMemoryRebound(to: WCHAR.self, capacity: tooltipCapacity) { buffer in
        WindowsWideString.copy(
          self.presentation.trayTooltip(showUsed: self.configuration.usageBarsShowUsed),
          to: buffer,
          capacity: tooltipCapacity)
      }
    }
    _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &iconData)
  }

  private func removeTrayIcon() {
    guard self.trayIconAdded, let messageWindow = self.messageWindow else { return }
    var iconData = NOTIFYICONDATAW()
    iconData.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    iconData.hWnd = messageWindow
    iconData.uID = Self.trayIconID
    _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &iconData)
    self.trayIconAdded = false
  }

  private func handleTrayCallback(lParam: LPARAM) -> LRESULT {
    switch UINT(UInt16(truncatingIfNeeded: lParam)) {
    case UINT(WM_RBUTTONUP), UINT(WM_CONTEXTMENU):
      self.showContextMenu()
    case UINT(WM_LBUTTONUP), UINT(NIN_SELECT), UINT(NIN_KEYSELECT):
      guard
        self.trayActivationGate.shouldHandle(
          timestamp: UInt32(bitPattern: GetMessageTime()))
      else {
        break
      }
      self.popup.toggleAnchoredFromTray()
    default:
      break
    }
    return 0
  }

  private func showContextMenu() {
    guard let menu = CreatePopupMenu(), let messageWindow = self.messageWindow else { return }
    defer { _ = DestroyMenu(menu) }

    self.appendMenuItem(menu, command: .refresh, title: "Refresh")
    self.appendMenuItem(menu, command: .popup, title: "Open CodexBar")
    self.appendMenuItem(menu, command: .about, title: "About CodexBar")
    _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    self.appendMenuItem(menu, command: .quit, title: "Quit CodexBar")

    var cursor = POINT()
    _ = GetCursorPos(&cursor)
    _ = SetForegroundWindow(messageWindow)
    _ = TrackPopupMenu(
      menu,
      UINT(TPM_RIGHTBUTTON),
      cursor.x,
      cursor.y,
      0,
      messageWindow,
      nil)
    _ = PostMessageW(messageWindow, UINT(WM_NULL), 0, 0)
  }

  private func appendMenuItem(_ menu: HMENU?, command: Command, title: String) {
    WindowsWideString.withPointer(title) { pointer in
      _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(command.rawValue), pointer)
    }
  }

  private func handleCommand(_ rawCommand: UInt16) {
    guard let command = Command(rawValue: rawCommand) else { return }
    switch command {
    case .refresh:
      self.requestRefresh()
    case .popup:
      self.popup.showAnchored()
    case .about:
      self.showAbout()
    case .quit:
      self.quit()
    }
  }

  func requestRefresh() {
    guard let messageWindow = self.messageWindow else { return }
    guard self.refreshGate.request() else { return }
    self.presentation = WindowsDashboardPresentation.make(
      snapshots: self.snapshotsForRefreshStart(),
      refreshedAt: self.presentation.refreshedAt ?? Date(),
      providers: self.configuration.enabledProviderIDs,
      isRefreshing: true)
    self.popup.update(self.presentation)
    self.updateTrayTooltip()

    let dataSource = self.dataSource
    let resultStore = self.refreshResultStore
    let window = WindowsWindowHandleBox(messageWindow)
    let generation = self.refreshGeneration
    _ = SetTimer(
      messageWindow,
      Self.refreshCompletionTimerID,
      Self.refreshCompletionPollMilliseconds,
      nil)
    self.refreshTask = Task.detached(priority: .utility) {
      @Sendable [dataSource, resultStore, window] in
      let snapshots = await dataSource.fetchProviderSnapshots()
      let box = WindowsRefreshResultBox(
        snapshots: snapshots,
        refreshedAt: Date(),
        generation: generation)
      resultStore.publish(box)
      _ = PostMessageW(
        window.value,
        Self.refreshCompletedMessage,
        0,
        0)
    }
  }

  @discardableResult
  func requestProviderConfigurationStatus(
    provider: WindowsProviderID,
    configuration: WindowsProviderConfiguration
  ) -> Foundation.UUID {
    let requestID = Foundation.UUID()
    guard let messageWindow = self.messageWindow else { return requestID }
    let client = self.providerConfigurationClient
    let store = self.configurationTaskResultStore
    let window = WindowsWindowHandleBox(messageWindow)
    Task.detached(priority: .utility) { @Sendable [client, store, window] in
      let result: WindowsConfigurationTaskResult
      do {
        result = WindowsConfigurationTaskResult(
          requestID: requestID,
          provider: provider,
          status: try client.status(provider: provider),
          didApply: false,
          appliedConfiguration: nil,
          safeErrorText: nil,
          canClearCredential: client.contains(provider: provider))
      } catch {
        result = Self.configurationFailure(
          requestID: requestID,
          provider: provider,
          error: error,
          canClearCredential: client.contains(provider: provider))
      }
      store.publish(result)
      _ = PostMessageW(window.value, Self.configurationTaskCompletedMessage, 0, 0)
    }
    return requestID
  }

  @discardableResult
  func applyProviderConfiguration(
    provider: WindowsProviderID,
    configuration: WindowsProviderConfiguration,
    credentialSetID: String?,
    values: [String: String]
  ) -> Foundation.UUID {
    let requestID = Foundation.UUID()
    guard let messageWindow = self.messageWindow else { return requestID }
    self.refreshTask?.cancel()
    self.refreshGeneration &+= 1
    self.credentialMutationRequestIDs.insert(requestID)
    let client = self.providerConfigurationClient
    let store = self.configurationTaskResultStore
    let window = WindowsWindowHandleBox(messageWindow)
    Task.detached(priority: .utility) { @Sendable [client, store, window] in
      let result: WindowsConfigurationTaskResult
      do {
        let status =
          if let credentialSetID {
            try client.save(
              provider: provider,
              credentialSetID: credentialSetID,
              values: values)
          } else {
            try client.clear(provider: provider)
          }
        result = WindowsConfigurationTaskResult(
          requestID: requestID,
          provider: provider,
          status: status,
          didApply: true,
          appliedConfiguration: configuration,
          safeErrorText: nil,
          canClearCredential: client.contains(provider: provider))
      } catch {
        result = Self.configurationFailure(
          requestID: requestID,
          provider: provider,
          error: error,
          canClearCredential: client.contains(provider: provider))
      }
      store.publish(result)
      _ = PostMessageW(window.value, Self.configurationTaskCompletedMessage, 0, 0)
    }
    return requestID
  }

  private static func configurationFailure(
    requestID: Foundation.UUID,
    provider: WindowsProviderID,
    error: Error,
    canClearCredential: Bool
  ) -> WindowsConfigurationTaskResult {
    WindowsConfigurationTaskResult(
      requestID: requestID,
      provider: provider,
      status: nil,
      didApply: false,
      appliedConfiguration: nil,
      safeErrorText: Self.safeConfigurationError(error),
      canClearCredential: canClearCredential)
  }

  private static func safeConfigurationError(_ error: Error) -> String {
    switch error {
    case let error as WindowsProviderCredentialVaultError:
      error.errorDescription ?? "Windows could not update the protected credential."
    case let error as WindowsProviderConfigurationError:
      error.errorDescription ?? "Windows could not update the provider configuration."
    default:
      "Windows could not update the protected credential."
    }
  }

  private func consumeConfigurationTaskResult() {
    guard let result = self.configurationTaskResultStore.take() else { return }
    let wasCredentialMutation = self.credentialMutationRequestIDs.remove(result.requestID) != nil
    var safeErrorText = result.safeErrorText
    if let applied = result.appliedConfiguration, result.didApply {
      if !self.updateProviderConfiguration(applied) {
        safeErrorText =
          "The credential was protected, but the WSL source preference could not be saved."
      }
    }
    self.popup.completeProviderConfigurationTask(
      requestID: result.requestID,
      provider: result.provider,
      status: result.status,
      didApply: result.didApply,
      safeErrorText: safeErrorText,
      canClearCredential: result.canClearCredential)
    if wasCredentialMutation, !result.didApply {
      self.requestRefresh()
    }
  }

  private func consumeRefreshResult() {
    guard let result = self.refreshResultStore.take() else { return }
    self.refreshTask = nil
    if let messageWindow = self.messageWindow {
      _ = KillTimer(messageWindow, Self.refreshCompletionTimerID)
    }
    let completion = self.refreshGate.complete()
    if result.generation != self.refreshGeneration {
      if completion == .restart { self.requestRefresh() }
      return
    }
    if completion == .restart {
      self.requestRefresh()
      return
    }
    if result.snapshots.contains(where: \.discardsRefreshResult) {
      self.requestRefresh()
      return
    }
    if result.snapshots.isEmpty {
      self.lastPublishedSnapshots.removeAll()
      self.presentation = WindowsDashboardPresentation.make(
        snapshots: [],
        refreshedAt: result.refreshedAt,
        providers: self.configuration.enabledProviderIDs)
      self.popup.update(self.presentation)
      self.updateTrayTooltip()
      return
    }
    let publication = WindowsProviderSnapshotPublisher.publish(result.snapshots) { snapshot in
      let retained = self.snapshotRetainingLastSuccess(snapshot)
      self.lastPublishedSnapshots[snapshot.provider] = retained
      self.presentation = WindowsDashboardPresentation.make(
        snapshots: Array(self.lastPublishedSnapshots.values),
        refreshedAt: result.refreshedAt,
        providers: self.configuration.enabledProviderIDs)
      self.popup.update(self.presentation)
      self.updateTrayTooltip()
    }
    if publication.requiresRefresh {
      self.requestRefresh()
    }
  }

  private func snapshotRetainingLastSuccess(_ snapshot: WindowsProviderSnapshot)
    -> WindowsProviderSnapshot
  {
    if snapshot.availability == .available {
      self.lastSuccessfulSnapshots[snapshot.provider] = snapshot
      return snapshot
    }
    return Self.snapshotRetainingLastSuccess(
      snapshot,
      cached: self.lastSuccessfulSnapshots[snapshot.provider])
  }

  static func snapshotRetainingLastSuccess(
    _ snapshot: WindowsProviderSnapshot,
    cached: WindowsProviderSnapshot?
  ) -> WindowsProviderSnapshot {
    guard let cached else { return snapshot }
    let error = [snapshot.safeErrorText, "Showing the last successful reading."]
      .compactMap { $0 }
      .joined(separator: " ")
    return WindowsProviderSnapshot(
      provider: cached.provider,
      availability: .error,
      usedPercent: cached.usedPercent,
      usageSummaryText: cached.usageSummaryText,
      resetText: cached.resetText,
      source: snapshot.source.isExplicitCredentialRoute ? snapshot.source : cached.source,
      safeErrorText: error,
      windows: cached.windows,
      planText: cached.planText,
      balanceText: cached.balanceText,
      accountText: cached.accountText,
      updatedAt: cached.updatedAt)
  }

  func toggleProvider(_ provider: WindowsProviderID) {
    guard let current = self.configuration.providers.first(where: { $0.id == provider }) else {
      return
    }
    self.configuration.setProviderEnabled(provider, enabled: !current.enabled)
    self.saveConfigurationAndRefresh()
  }

  func toggleUsageBarsShowUsed() {
    let previous = self.configuration.usageBarsShowUsed
    self.configuration.usageBarsShowUsed.toggle()
    guard self.saveConfiguration() else {
      self.configuration.usageBarsShowUsed = previous
      self.popup.updateConfiguration(self.configuration)
      return
    }
    self.updateTrayTooltip()
  }

  @discardableResult
  func updateRefreshIntervalMinutes(_ minutes: Int) -> Bool {
    guard WindowsAppConfiguration.allowedRefreshIntervalMinutes.contains(minutes) else {
      return false
    }
    guard minutes != self.configuration.refreshIntervalMinutes else { return true }
    let previous = self.configuration.refreshIntervalMinutes
    guard self.installRefreshTimer(minutes: minutes) else {
      self.showStartupError("CodexBar could not update its refresh interval.")
      return false
    }
    self.configuration.refreshIntervalMinutes = minutes
    guard self.saveConfiguration() else {
      self.configuration.refreshIntervalMinutes = previous
      _ = self.installRefreshTimer(minutes: previous)
      self.popup.updateConfiguration(self.configuration)
      return false
    }
    return true
  }

  func toggleRunAtStartup() {
    let previous = self.configuration.runAtStartup
    let enabled = !previous
    do {
      try WindowsStartupTask.setEnabled(enabled)
    } catch {
      self.showStartupError("CodexBar could not update the Windows startup task.")
      return
    }
    self.configuration.runAtStartup = enabled
    guard self.saveConfiguration() else {
      self.configuration.runAtStartup = previous
      try? WindowsStartupTask.setEnabled(previous)
      self.popup.updateConfiguration(self.configuration)
      return
    }
  }

  func moveProviderToTop(_ provider: WindowsProviderID) {
    let ordered = self.configuration.providers.indices.sorted {
      let lhs = self.configuration.providers[$0]
      let rhs = self.configuration.providers[$1]
      return lhs.order == rhs.order ? lhs.id.rawValue < rhs.id.rawValue : lhs.order < rhs.order
    }
    let enabled = ordered.filter { self.configuration.providers[$0].enabled }
    guard
      let sourcePosition = enabled.firstIndex(where: {
        self.configuration.providers[$0].id == provider
      }),
      sourcePosition > 0
    else {
      return
    }
    let availableOrders = enabled.map { self.configuration.providers[$0].order }
    var reordered = enabled
    let sourceIndex = reordered.remove(at: sourcePosition)
    reordered.insert(sourceIndex, at: 0)
    for (index, order) in zip(reordered, availableOrders) {
      self.configuration.providers[index].order = order
    }
    self.saveConfigurationAndRefresh()
  }

  func moveProvider(_ provider: WindowsProviderID, direction: Int) {
    let ordered = self.configuration.providers.indices.sorted {
      let lhs = self.configuration.providers[$0]
      let rhs = self.configuration.providers[$1]
      return lhs.order == rhs.order ? lhs.id.rawValue < rhs.id.rawValue : lhs.order < rhs.order
    }
    let enabled = ordered.filter { self.configuration.providers[$0].enabled }
    guard
      let position = enabled.firstIndex(where: { self.configuration.providers[$0].id == provider })
    else {
      return
    }
    let destination = position + direction
    guard enabled.indices.contains(destination) else { return }
    let lhs = enabled[position]
    let rhs = enabled[destination]
    let lhsOrder = self.configuration.providers[lhs].order
    self.configuration.providers[lhs].order = self.configuration.providers[rhs].order
    self.configuration.providers[rhs].order = lhsOrder
    self.saveConfigurationAndRefresh()
  }

  @discardableResult
  func updateProviderConfiguration(_ provider: WindowsProviderConfiguration) -> Bool {
    guard let index = self.configuration.providers.firstIndex(where: { $0.id == provider.id })
    else {
      return false
    }
    self.configuration.providers[index] = provider
    return self.saveConfigurationAndRefresh()
  }

  @discardableResult
  private func saveConfigurationAndRefresh() -> Bool {
    guard self.saveConfiguration() else { return false }
    self.presentation = WindowsDashboardPresentation.make(
      snapshots: self.snapshotsForRefreshPresentation(),
      refreshedAt: self.presentation.refreshedAt ?? Date(),
      providers: self.configuration.enabledProviderIDs,
      isRefreshing: true)
    self.popup.update(self.presentation)
    self.requestRefresh()
    return true
  }

  private func snapshotsForRefreshPresentation() -> [WindowsProviderSnapshot] {
    self.lastSuccessfulSnapshots.values.map { snapshot in
      guard
        let provider = self.configuration.providers.first(where: { $0.id == snapshot.provider })
      else { return snapshot }
      let route = self.credentialRouteResolver.resolve(snapshot.provider)
      let manualLabel =
        route.manualSelected
        ? route.manualLabel ?? "Manual credential"
        : nil
      return Self.snapshotForRefreshPresentation(
        snapshot,
        configuration: provider,
        manualCredentialLabel: manualLabel)
    }
  }

  private func snapshotsForRefreshStart() -> [WindowsProviderSnapshot] {
    self.configuration.enabledProviderIDs.compactMap { providerID in
      guard let provider = self.configuration.providers.first(where: { $0.id == providerID }) else {
        return nil
      }
      let snapshot =
        self.lastPublishedSnapshots[providerID]
        ?? self.lastSuccessfulSnapshots[providerID]
        ?? WindowsProviderSnapshot(
          provider: providerID,
          availability: .loading,
          source: WindowsProviderSourcePresentation.configuredFallback(configuration: provider))
      let route = self.credentialRouteResolver.resolve(providerID)
      let manualLabel =
        route.manualSelected
        ? route.manualLabel ?? "Manual credential"
        : nil
      return Self.snapshotForRefreshPresentation(
        snapshot,
        configuration: provider,
        manualCredentialLabel: manualLabel)
    }
  }

  static func snapshotForRefreshPresentation(
    _ snapshot: WindowsProviderSnapshot,
    configuration: WindowsProviderConfiguration,
    manualCredentialLabel: String?
  ) -> WindowsProviderSnapshot {
    guard manualCredentialLabel != nil || snapshot.source.isManualCredentialRoute else {
      return snapshot
    }
    let distribution =
      configuration.sourceMode == .wsl
      ? configuration.wslDistro
      : snapshot.source.distributionLabel
    let kind =
      manualCredentialLabel.map(WindowsProviderSourcePresentation.Kind.manual) ?? .automatic
    return snapshot.replacingSource(
      WindowsProviderSourcePresentation(
        distributionLabel: distribution,
        kind: kind,
        isResolved: false))
  }

  @discardableResult
  private func saveConfiguration() -> Bool {
    self.configuration = self.configuration.mergingCatalogDefaults()
    do {
      try self.configurationStore?.save(self.configuration)
    } catch {
      self.showStartupError("CodexBar could not save its Windows configuration.")
      return false
    }
    self.popup.updateConfiguration(self.configuration)
    return true
  }

  private func installRefreshTimer(minutes: Int) -> Bool {
    let milliseconds = UINT(minutes * 60 * 1000)
    return SetTimer(self.messageWindow, Self.refreshTimerID, milliseconds, nil) != 0
  }

  private func showAbout() {
    WindowsWideString.withPointer("CodexBar") { title in
      WindowsWideString.withPointer(
        "CodexBar for Windows\n\nProvider usage in the notification area.\nNo credentials are displayed."
      ) { message in
        _ = MessageBoxW(self.popup.window, message, title, UINT(MB_OK | MB_ICONINFORMATION))
      }
    }
  }

  private func showStartupError(_ text: String) {
    WindowsWideString.withPointer("CodexBar") { title in
      WindowsWideString.withPointer(text) { message in
        _ = MessageBoxW(nil, message, title, UINT(MB_OK | MB_ICONERROR))
      }
    }
  }

  private func quit() {
    self.releaseWindowsResources()
  }

  private func releaseWindowsResources() {
    if let messageWindow = self.messageWindow {
      _ = KillTimer(messageWindow, Self.refreshTimerID)
      _ = KillTimer(messageWindow, Self.refreshCompletionTimerID)
    }
    self.removeTrayIcon()
    self.applicationIcon.remove(from: self.popup.window)
    self.popup.destroy()
    if let messageWindow = self.messageWindow {
      _ = DestroyWindow(messageWindow)
    }
    self.messageWindow = nil
  }
}
