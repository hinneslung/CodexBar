#if canImport(CodexBarWindows)
  import Testing
  @testable import CodexBarWindows

  struct WindowsRefreshGateTests {
    @Test
    func `configuration refresh queued during an older refresh discards and restarts`() {
      var gate = WindowsRefreshGate()

      let firstRequest = gate.request()
      let queuedRequest = gate.request()
      let firstCompletion = gate.complete()
      let restartedRequest = gate.request()
      let restartedCompletion = gate.complete()

      #expect(firstRequest)
      #expect(!queuedRequest)
      #expect(firstCompletion == .restart)
      #expect(restartedRequest)
      #expect(restartedCompletion == .publish)
    }

    @Test
    func `multiple requests during one refresh coalesce into one restart`() {
      var gate = WindowsRefreshGate()

      let firstRequest = gate.request()
      let firstQueuedRequest = gate.request()
      let secondQueuedRequest = gate.request()
      let firstCompletion = gate.complete()
      let restartedRequest = gate.request()
      let restartedCompletion = gate.complete()

      #expect(firstRequest)
      #expect(!firstQueuedRequest)
      #expect(!secondQueuedRequest)
      #expect(firstCompletion == .restart)
      #expect(restartedRequest)
      #expect(restartedCompletion == .publish)
    }
  }
#endif
