#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  import WinSDK
  @testable import CodexBarWindows

  @Suite("Windows hidden process runner")
  struct WindowsHiddenProcessRunnerTests {
    @Test("every launch requests a Unicode no-window child with an explicit handle list")
    func usesNoWindowCreationFlags() {
      #expect(WindowsHiddenProcessRunner.creationFlags & DWORD(CREATE_NO_WINDOW) != 0)
      #expect(WindowsHiddenProcessRunner.creationFlags & DWORD(CREATE_UNICODE_ENVIRONMENT) != 0)
      #expect(WindowsHiddenProcessRunner.creationFlags & DWORD(EXTENDED_STARTUPINFO_PRESENT) != 0)
    }

    @Test("Windows command line quoting preserves spaces quotes and trailing slashes")
    func quotesArguments() {
      let command = WindowsHiddenProcessRunner.commandLine(
        executablePath: "C:\\Program Files\\CodexBar\\CodexBarCLI.exe",
        arguments: ["usage", "a b", "quoted\"value", "C:\\trailing\\"])
      #expect(command.hasPrefix("\"C:\\Program Files\\CodexBar\\CodexBarCLI.exe\" usage"))
      #expect(command.contains("\"a b\""))
      #expect(command.contains("\"quoted\\\"value\""))
      #expect(command.hasSuffix("C:\\trailing\\"))
    }

    @Test("environment overrides are Unicode scoped and case insensitive")
    func buildsEnvironmentBlock() throws {
      let block = try WindowsHiddenProcessRunner.environmentBlock(
        base: ["Path": "old", "KEEP": "value"],
        overrides: ["PATH": "new", "TOKEN": "secret"])
      let decoded = String(decoding: block, as: UTF16.self)
      #expect(decoded.contains("PATH=new\0"))
      #expect(!decoded.contains("Path=old\0"))
      #expect(decoded.contains("KEEP=value\0"))
      #expect(decoded.contains("TOKEN=secret\0"))
      #expect(block.suffix(2).allSatisfy { $0 == 0 })
    }

    @Test("hidden runner captures output and exit status without a shell")
    func capturesOutput() throws {
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/where.exe").path
      let result = try WindowsHiddenProcessRunner.run(
        executablePath: executable,
        arguments: ["wsl.exe"],
        timeout: 5,
        maximumOutputBytes: 4096)
      #expect(
        result.exitCode == 0,
        "stderr: \(String(bytes: result.standardError, encoding: .utf8) ?? "<non-UTF-8>")")
      let standardOutput = try #require(String(bytes: result.standardOutput, encoding: .utf8))
      #expect(standardOutput.lowercased().contains("wsl.exe"))
    }

    @Test("parent closes child output handles so readers observe process EOF")
    func readersObserveProcessEOF() throws {
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/where.exe").path
      let startedAt = Date()
      let result = try WindowsHiddenProcessRunner.run(
        executablePath: executable,
        arguments: ["cmd.exe"],
        timeout: 5,
        maximumOutputBytes: 4096)

      #expect(result.exitCode == 0)
      #expect(Date().timeIntervalSince(startedAt) < 4)
    }

    @Test("stdin writer obeys the process deadline when the child never reads")
    func nonReadingChildDoesNotHangCleanup() {
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/ping.exe").path
      let startedAt = Date()

      do {
        _ = try WindowsHiddenProcessRunner.run(
          executablePath: executable,
          arguments: ["-n", "6", "127.0.0.1"],
          timeout: 0.1,
          maximumOutputBytes: 4096,
          standardInput: Data(repeating: 0x78, count: 1_048_576))
        Issue.record("Expected the blocked stdin writer to time out")
      } catch WindowsCanonicalCLIError.timedOut {
        // Expected.
      } catch {
        Issue.record("Expected timedOut, received \(error)")
      }
      #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test("task cancellation terminates a hidden child promptly")
    func cancellationStopsChild() async {
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/ping.exe").path
      let startedAt = Date()
      let task = Task.detached {
        try WindowsHiddenProcessRunner.run(
          executablePath: executable,
          arguments: ["-n", "30", "127.0.0.1"],
          timeout: 60,
          maximumOutputBytes: 4096)
      }
      try? await Task.sleep(for: .milliseconds(150))
      task.cancel()
      do {
        _ = try await task.value
        Issue.record("Expected the hidden child to be cancelled")
      } catch WindowsCanonicalCLIError.cancelled {
        // Expected.
      } catch {
        Issue.record("Expected cancelled, received \(error)")
      }
      #expect(Date().timeIntervalSince(startedAt) < 3)
    }

    @Test("output readers drain before a large stdin write")
    func readersStartBeforeInputWriter() throws {
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe").path
      let script = """
        [Console]::Out.Write(('o' * 131072));
        $received = [Console]::In.ReadToEnd();
        [Console]::Error.Write(('e' * 131072));
        if ($received.Length -ne 131072) { exit 7 }
        """
      let encodedScript = Data(
        script.utf16.flatMap { codeUnit in
          [UInt8(truncatingIfNeeded: codeUnit), UInt8(truncatingIfNeeded: codeUnit >> 8)]
        }
      ).base64EncodedString()

      let result = try WindowsHiddenProcessRunner.run(
        executablePath: executable,
        arguments: ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodedScript],
        timeout: 10,
        maximumOutputBytes: 200_000,
        standardInput: Data(repeating: 0x78, count: 131_072))

      #expect(result.exitCode == 0)
      #expect(result.standardOutput.count == 131_072)
      #expect(result.standardError.count == 131_072)
    }

    @Test("hidden runner writes stdin through a closed non-command-line pipe")
    func pipesStandardInput() throws {
      let secret = "fixture-stdin-only-value"
      let executable = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
      )
      .appendingPathComponent("System32/findstr.exe").path
      let arguments = [".*"]
      #expect(
        !WindowsHiddenProcessRunner.commandLine(
          executablePath: executable,
          arguments: arguments
        ).contains(secret))

      let result = try WindowsHiddenProcessRunner.run(
        executablePath: executable,
        arguments: arguments,
        timeout: 5,
        maximumOutputBytes: 4096,
        standardInput: Data(secret.utf8))
      #expect(result.exitCode == 0)
      let standardOutput = try #require(String(bytes: result.standardOutput, encoding: .utf8))
      #expect(standardOutput.contains(secret))
    }

    @Test("anonymous stdin pipe inherits only the child read end")
    func pipeWriteEndDoesNotInherit() throws {
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true
      let handles = try WindowsHiddenProcessRunner.openInput(
        Data("fixture".utf8), security: &security)
      defer {
        _ = CloseHandle(handles.child)
        if let parent = handles.parent { _ = CloseHandle(parent) }
      }
      var childFlags: DWORD = 0
      var parentFlags: DWORD = 0
      #expect(GetHandleInformation(handles.child, &childFlags))
      let parent = try #require(handles.parent)
      #expect(GetHandleInformation(parent, &parentFlags))
      #expect(childFlags & DWORD(HANDLE_FLAG_INHERIT) != 0)
      #expect(parentFlags & DWORD(HANDLE_FLAG_INHERIT) == 0)
    }
  }
#endif
