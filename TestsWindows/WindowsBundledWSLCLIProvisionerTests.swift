#if canImport(CodexBarWindows)
  import Foundation
  import Testing
  @testable import CodexBarWindows

  @Suite("Windows bundled WSL CLI provisioner")
  struct WindowsBundledWSLCLIProvisionerTests {
    @Test("valid release payload is accepted without following links")
    func loadsValidPayload() throws {
      let directory = try Self.payloadDirectory(version: "0.54.1")
      defer { try? FileManager.default.removeItem(at: directory) }

      let payload = WindowsBundledWSLCLIPayload.load(from: directory)

      #expect(payload?.version == "0.54.1")
      #expect(payload?.executable.lastPathComponent == "CodexBarCLI")
      #expect(payload?.executableChecksum.lastPathComponent == "CodexBarCLI.sha256")
      #expect(payload?.resourceBundle.lastPathComponent == "CodexBar_CodexBarCore.bundle")
      #expect(payload?.stagingLauncher.lastPathComponent == "CodexBarStagingLauncher")
      #expect(
        payload?.stagingLauncherChecksum.lastPathComponent == "CodexBarStagingLauncher.sha256")
      #expect(payload?.executableChecksumValue == String(repeating: "0", count: 64))
      #expect(payload?.stagingLauncherChecksumValue == String(repeating: "0", count: 64))
    }

    @Test("unsafe release version cannot become a WSL path")
    func rejectsUnsafeVersion() throws {
      let directory = try Self.payloadDirectory(version: "../../other")
      defer { try? FileManager.default.removeItem(at: directory) }

      #expect(WindowsBundledWSLCLIPayload.load(from: directory) == nil)
      #expect(WindowsBundledWSLCLIPayload.isSafeVersion("v0.54.1-beta_1"))
      #expect(!WindowsBundledWSLCLIPayload.isSafeVersion("0.54.1/bad"))
    }

    @Test("install plan uses direct fixed commands in an application owned directory")
    func createsDirectInstallPlan() {
      let destination = WindowsBundledWSLCLIProvisioner.destination(
        linuxHome: "/home/example",
        version: "0.54.1")
      let commands = WindowsBundledWSLCLIProvisioner.installCommands(
        payloadLinuxDirectory: "/mnt/c/Program Files/CodexBar/wsl-cli",
        destination: destination)

      #expect(
        destination.executable == "/home/example/.local/share/codexbar-windows/0.54.1/CodexBarCLI")
      #expect(
        commands.first == [
          "/usr/bin/mkdir", "-p", destination.root, destination.resourceBundle,
        ])
      #expect(
        commands.contains([
          "/usr/bin/cp", "--", "/mnt/c/Program Files/CodexBar/wsl-cli/CodexBarCLI",
          "\(destination.root)/.CodexBarCLI.installing",
        ]))
      #expect(
        commands.contains([
          "/usr/bin/cp", "--", "/mnt/c/Program Files/CodexBar/wsl-cli/CodexBarCLI.sha256",
          "\(destination.root)/.CodexBarCLI.sha256.installing",
        ]))
      #expect(commands.allSatisfy { $0.first?.hasPrefix("/usr/bin/") == true })
      #expect(commands.allSatisfy { !$0.contains("sh") && !$0.contains("bash") })
    }

    @Test("translated WSL paths are bounded and absolute")
    func decodesTranslatedPath() {
      #expect(
        WindowsBundledWSLCLIProvisioner.decodedAbsoluteLinuxPath(
          Data("/mnt/c/Program Files/CodexBar/wsl-cli\n".utf8))
          == "/mnt/c/Program Files/CodexBar/wsl-cli")
      #expect(
        WindowsBundledWSLCLIProvisioner.decodedAbsoluteLinuxPath(
          Data("relative/path\n".utf8)) == nil)
      #expect(
        WindowsBundledWSLCLIProvisioner.decodedAbsoluteLinuxPath(
          Data("/mnt/c/path\u{0}other\n".utf8)) == nil)
    }

    @Test("payload location is adjacent to the packaged executable")
    func resolvesPackagedPayloadLocation() {
      let executable = URL(fileURLWithPath: "C:/Program Files/CodexBar/CodexBar.exe")
      #expect(
        WindowsBundledWSLCLIProvisioner.defaultPayloadDirectory(executableURL: executable)?.path
          == URL(fileURLWithPath: "C:/Program Files/CodexBar/wsl-cli", isDirectory: true).path)
    }

    @Test("same version payload with a mismatched CLI checksum is never returned")
    func rejectsTamperedInstalledCLI() throws {
      let directory = try Self.payloadDirectory(version: "0.54.1")
      defer { try? FileManager.default.removeItem(at: directory) }
      let expected = String(repeating: "a", count: 64)
      let actual = String(repeating: "b", count: 64)
      let provisioner = WindowsBundledWSLCLIProvisioner(
        payloadDirectory: directory,
        linuxHomeResolver: { _ in "/home/example" },
        commandRunner: { _, arguments in
          let command = Array(arguments.dropFirst(3))
          let output: String
          let exitCode: Int32
          switch command.first {
          case "/usr/bin/wslpath":
            output = "/mnt/c/CodexBar/wsl-cli\n"
            exitCode = 0
          case "/usr/bin/test" where command.dropFirst().first == "-L":
            output = ""
            exitCode = 1
          case "/usr/bin/test":
            output = ""
            exitCode = 0
          case "/usr/bin/cat" where command.last?.hasSuffix("/VERSION") == true:
            output = "0.54.1\n"
            exitCode = 0
          case "/usr/bin/cat" where command.last?.hasSuffix("/CodexBarCLI.sha256") == true:
            output = "\(expected)  CodexBarCLI\n"
            exitCode = 0
          case "/usr/bin/sha256sum" where command.last?.hasSuffix("/CodexBarCLI") == true:
            output = "\(actual)  CodexBarCLI\n"
            exitCode = 0
          case "/usr/bin/cat":
            output = "\(expected)  CodexBarStagingLauncher\n"
            exitCode = 0
          case "/usr/bin/sha256sum":
            output = "\(expected)  CodexBarStagingLauncher\n"
            exitCode = 0
          default:
            output = ""
            exitCode = 0
          }
          return WindowsHiddenProcessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            exitCode: exitCode)
        })

      #expect(
        provisioner.provision(distribution: "Ubuntu", windowsDirectory: "C:\\Windows") == nil)
    }

    @Test("same version stale launcher is replaced from the current payload")
    func replacesSameVersionStaleLauncher() throws {
      let directory = try Self.payloadDirectory(version: "0.54.1")
      defer { try? FileManager.default.removeItem(at: directory) }
      let bundled = String(repeating: "0", count: 64)
      let stale = String(repeating: "a", count: 64)
      let commands = CommandRecorder()
      let provisioner = WindowsBundledWSLCLIProvisioner(
        payloadDirectory: directory,
        linuxHomeResolver: { _ in "/home/example" },
        commandRunner: { _, arguments in
          let command = Array(arguments.dropFirst(3))
          commands.append(command.joined(separator: " "))
          let output: String
          let exitCode: Int32
          switch command.first {
          case "/usr/bin/wslpath":
            output = "/mnt/c/CodexBar/wsl-cli\n"
            exitCode = 0
          case "/usr/bin/test" where command.dropFirst().first == "-L":
            output = ""
            exitCode = 1
          case "/usr/bin/test":
            output = ""
            exitCode = 0
          case "/usr/bin/cat" where command.last?.hasSuffix("/VERSION") == true:
            output = "0.54.1\n"
            exitCode = 0
          case "/usr/bin/cat" where command.last?.hasSuffix("/CodexBarCLI.sha256") == true:
            output = "\(bundled)  CodexBarCLI\n"
            exitCode = 0
          case "/usr/bin/sha256sum" where command.last?.hasSuffix("/CodexBarCLI") == true:
            output = "\(bundled)  CodexBarCLI\n"
            exitCode = 0
          case "/usr/bin/cat":
            output = "\(stale)  CodexBarStagingLauncher\n"
            exitCode = 0
          case "/usr/bin/sha256sum":
            output = "\(stale)  CodexBarStagingLauncher\n"
            exitCode = 0
          default:
            output = ""
            exitCode = 0
          }
          return WindowsHiddenProcessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            exitCode: exitCode)
        })

      #expect(
        provisioner.provision(distribution: "Ubuntu", windowsDirectory: "C:\\Windows") == nil)
      #expect(
        commands.contains("CodexBarStagingLauncher.installing"))
    }

    @Test("bundled payload can be provisioned and executed in a live WSL distribution")
    func provisionsLiveWSLPayload() throws {
      let environment = ProcessInfo.processInfo.environment
      guard environment["CODEXBAR_LIVE_WSL_PROVISION_TESTS"] == "1" else { return }
      let distribution = try #require(environment["CODEXBAR_LIVE_WSL_DISTRIBUTION"])
      let linuxHome = try #require(environment["CODEXBAR_LIVE_WSL_HOME"])
      #expect(WindowsWSLDistributionRegistry.isSafeDistributionName(distribution))
      #expect(WindowsBundledWSLCLIProvisioner.isSafeLinuxHome(linuxHome))
      guard WindowsWSLDistributionRegistry.isSafeDistributionName(distribution),
        WindowsBundledWSLCLIProvisioner.isSafeLinuxHome(linuxHome)
      else { return }
      let version = "codexbar-live-provision-test"
      let payloadDirectory = try Self.payloadDirectory(
        version: version,
        executableContents: "#!/bin/sh\nprintf 'CodexBar bundled WSL live test\\n'\n")
      defer { try? FileManager.default.removeItem(at: payloadDirectory) }

      let windowsDirectory = environment["WINDIR"] ?? "C:\\Windows"
      let wslExecutable = URL(fileURLWithPath: windowsDirectory)
        .appendingPathComponent("System32/wsl.exe", isDirectory: false).path
      let destination = WindowsBundledWSLCLIProvisioner.destination(
        linuxHome: linuxHome,
        version: version)
      defer {
        _ = try? WindowsHiddenProcessRunner.run(
          executablePath: wslExecutable,
          arguments: [
            "-d", distribution, "--", "/usr/bin/rm", "-rf", "--", destination.root,
          ],
          timeout: 30,
          maximumOutputBytes: 16 * 1024)
      }

      let provisioner = WindowsBundledWSLCLIProvisioner(
        payloadDirectory: payloadDirectory,
        linuxHomeResolver: { _ in linuxHome })
      let executable = try #require(
        provisioner.provision(
          distribution: distribution,
          windowsDirectory: windowsDirectory))
      let result = try WindowsHiddenProcessRunner.run(
        executablePath: wslExecutable,
        arguments: ["-d", distribution, "--", executable, "--version"],
        timeout: 30,
        maximumOutputBytes: 16 * 1024)

      #expect(result.exitCode == 0)
      #expect(
        String(decoding: result.standardOutput, as: UTF8.self) == "CodexBar bundled WSL live test\n"
      )
    }

    private static func payloadDirectory(
      version: String,
      executableContents: String = "executable"
    ) throws -> URL {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-bundled-cli-\(UUID().uuidString)", isDirectory: true)
      let resources = directory.appendingPathComponent(
        "CodexBar_CodexBarCore.bundle",
        isDirectory: true)
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      try Data(executableContents.utf8).write(
        to: directory.appendingPathComponent("CodexBarCLI", isDirectory: false))
      try Data(
        (String(repeating: "0", count: 64) + "  CodexBarCLI\n").utf8
      ).write(
        to: directory.appendingPathComponent("CodexBarCLI.sha256", isDirectory: false))
      try Data(executableContents.utf8).write(
        to: directory.appendingPathComponent("CodexBarStagingLauncher", isDirectory: false))
      try Data(
        (String(repeating: "0", count: 64) + "  CodexBarStagingLauncher\n").utf8
      ).write(
        to: directory.appendingPathComponent(
          "CodexBarStagingLauncher.sha256",
          isDirectory: false))
      try Data(version.utf8).write(
        to: directory.appendingPathComponent("VERSION", isDirectory: false))
      try Data("resource".utf8).write(
        to: resources.appendingPathComponent("ProviderManifest.json", isDirectory: false))
      return directory
    }

    private final class CommandRecorder: @unchecked Sendable {
      private let lock = NSLock()
      private var commands: [String] = []

      func append(_ command: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.commands.append(command)
      }

      func contains(_ fragment: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.commands.contains { $0.contains(fragment) }
      }
    }
  }
#endif
