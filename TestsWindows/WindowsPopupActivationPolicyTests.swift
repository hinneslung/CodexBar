#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  struct WindowsPopupActivationPolicyTests {
    @Test
    func `late inactive notification cannot close a popup just shown from the tray`() {
      var policy = WindowsPopupActivationPolicy()

      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      #expect(policy.deactivated(automaticallyHides: true) == .scheduleDeferredHide)
      #expect(
        policy.postTrayActivationTimerFired(isPopupVisible: true)
          == .cancelDeferredHideAndReactivate)
      #expect(policy.deactivated(automaticallyHides: true) == .scheduleDeferredHide)
    }

    @Test
    func `deferred hide firing before post activation reactivates instead of hiding`() {
      var policy = WindowsPopupActivationPolicy()

      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      #expect(policy.deactivated(automaticallyHides: true) == .scheduleDeferredHide)
      #expect(
        policy.deferredHideTimerFired(isPopupVisible: true)
          == .cancelDeferredHideAndReactivate)
      #expect(policy.postTrayActivationTimerFired(isPopupVisible: true) == .none)
    }

    @Test
    func `outside deactivation after handshake performs the deferred hide`() {
      var policy = WindowsPopupActivationPolicy()

      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      #expect(
        policy.postTrayActivationTimerFired(isPopupVisible: true)
          == .cancelDeferredHideAndReactivate)
      #expect(policy.deactivated(automaticallyHides: true) == .scheduleDeferredHide)
      #expect(policy.deferredHideTimerFired(isPopupVisible: true) == .hide)
    }

    @Test
    func `duplicate tray activation is ignored until the show handshake completes`() {
      var policy = WindowsPopupActivationPolicy()

      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      #expect(policy.trayActivated(isPopupVisible: true) == .ignoreDuplicateTrayActivation)
      #expect(
        policy.postTrayActivationTimerFired(isPopupVisible: true)
          == .cancelDeferredHideAndReactivate)
      #expect(policy.trayActivated(isPopupVisible: true) == .hide)
    }

    @Test
    func `hiding before delayed activation prevents the popup from reopening`() {
      var policy = WindowsPopupActivationPolicy()

      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      policy.popupHidden()
      #expect(policy.postTrayActivationTimerFired(isPopupVisible: false) == .none)
    }

    @Test
    func `one physical tray activation cannot toggle twice`() {
      var gate = WindowsTrayActivationGate()
      var policy = WindowsPopupActivationPolicy()

      let firstOpen = gate.shouldHandle(timestamp: 1_000)
      #expect(firstOpen)
      #expect(policy.trayActivated(isPopupVisible: false) == .showFromTray)
      #expect(
        policy.postTrayActivationTimerFired(isPopupVisible: true)
          == .cancelDeferredHideAndReactivate)
      let duplicateOpen = gate.shouldHandle(timestamp: 1_012)
      #expect(!duplicateOpen)

      let firstClose = gate.shouldHandle(timestamp: 2_000)
      #expect(firstClose)
      #expect(policy.trayActivated(isPopupVisible: true) == .hide)
      policy.popupHidden()
      let duplicateClose = gate.shouldHandle(timestamp: 2_009)
      #expect(!duplicateClose)
    }

    @Test
    func `tray activation coalescing survives timestamp wraparound`() {
      var gate = WindowsTrayActivationGate()

      let beforeWrap = gate.shouldHandle(timestamp: UInt32.max - 100)
      let afterWrapDuplicate = gate.shouldHandle(timestamp: 20)
      let afterWrapActivation = gate.shouldHandle(timestamp: 400)
      #expect(beforeWrap)
      #expect(!afterWrapDuplicate)
      #expect(afterWrapActivation)
    }
  }
#endif
