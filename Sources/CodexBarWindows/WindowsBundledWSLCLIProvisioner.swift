import Foundation
import WinSDK

struct WindowsBundledWSLCLIPayload: Equatable, Sendable {
  let directory: URL
  let executable: URL
  let executableChecksum: URL
  let versionFile: URL
  let resourceBundle: URL
  let stagingLauncher: URL
  let stagingLauncherChecksum: URL
  let version: String
  let executableChecksumValue: String
  let stagingLauncherChecksumValue: String

  static func load(
    from directory: URL?,
    fileManager: FileManager = .default
  ) -> Self? {
    guard let directory else { return nil }
    let executable = directory.appendingPathComponent("CodexBarCLI", isDirectory: false)
    let executableChecksum = directory.appendingPathComponent(
      "CodexBarCLI.sha256",
      isDirectory: false)
    let versionFile = directory.appendingPathComponent("VERSION", isDirectory: false)
    let resourceBundle = directory.appendingPathComponent(
      "CodexBar_CodexBarCore.bundle",
      isDirectory: true)
    let stagingLauncher = directory.appendingPathComponent(
      "CodexBarStagingLauncher",
      isDirectory: false)
    let stagingLauncherChecksum = directory.appendingPathComponent(
      "CodexBarStagingLauncher.sha256",
      isDirectory: false)
    guard Self.isRegularFile(executable, fileManager: fileManager),
      Self.isRegularFile(executableChecksum, fileManager: fileManager),
      Self.isRegularFile(versionFile, fileManager: fileManager),
      Self.isRegularFile(stagingLauncher, fileManager: fileManager),
      Self.isRegularFile(stagingLauncherChecksum, fileManager: fileManager),
      Self.isDirectory(resourceBundle, fileManager: fileManager),
      let data = try? Data(contentsOf: versionFile),
      let rawVersion = String(data: data, encoding: .utf8),
      let executableChecksumData = try? Data(contentsOf: executableChecksum),
      let executableChecksumValue = Self.checksumValue(executableChecksumData),
      let stagingLauncherChecksumData = try? Data(contentsOf: stagingLauncherChecksum),
      let stagingLauncherChecksumValue = Self.checksumValue(stagingLauncherChecksumData)
    else { return nil }

    let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isSafeVersion(version) else { return nil }
    return Self(
      directory: directory,
      executable: executable,
      executableChecksum: executableChecksum,
      versionFile: versionFile,
      resourceBundle: resourceBundle,
      stagingLauncher: stagingLauncher,
      stagingLauncherChecksum: stagingLauncherChecksum,
      version: version,
      executableChecksumValue: executableChecksumValue,
      stagingLauncherChecksumValue: stagingLauncherChecksumValue)
  }

  static func isSafeVersion(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 64 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 48...57, 65...90, 97...122, 45, 46, 95:
        true
      default:
        false
      }
    }
  }

  private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return false }
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func checksumValue(_ data: Data) -> String? {
    // swiftlint:disable:next optional_data_string_conversion
    let decoded = String(decoding: data, as: UTF8.self)
    let line = decoded.components(separatedBy: .newlines).first ?? ""
    guard let token = line.split(whereSeparator: \.isWhitespace).first else { return nil }
    let value = String(token).lowercased()
    guard value.utf8.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
    return value
  }
}

/// Installs the same-version Linux CLI carried by the Windows release when WSL has no system CLI.
/// The payload stays upstream-owned and is copied only into CodexBar's versioned application data.
struct WindowsBundledWSLCLIProvisioner: Sendable {
  typealias CommandRunner =
    @Sendable (_ executablePath: String, _ arguments: [String]) -> WindowsHiddenProcessResult?
  typealias LinuxHomeResolver = @Sendable (_ distribution: String) -> String?

  private static let maximumOutputBytes = 16 * 1024
  private static let timeout: TimeInterval = 120

  private let payloadDirectory: URL?
  private let linuxHomeResolver: LinuxHomeResolver
  private let commandRunner: CommandRunner

  init(
    payloadDirectory: URL? = Self.defaultPayloadDirectory(),
    linuxHomeResolver: @escaping LinuxHomeResolver = { distribution in
      WindowsWSLDefaultUserHome.linuxPath(distributionName: distribution)
    },
    commandRunner: @escaping CommandRunner = { executablePath, arguments in
      try? WindowsHiddenProcessRunner.run(
        executablePath: executablePath,
        arguments: arguments,
        timeout: Self.timeout,
        maximumOutputBytes: Self.maximumOutputBytes)
    }
  ) {
    self.payloadDirectory = payloadDirectory
    self.linuxHomeResolver = linuxHomeResolver
    self.commandRunner = commandRunner
  }

  func provision(distribution: String, windowsDirectory: String) -> String? {
    guard WindowsWSLDistributionRegistry.isSafeDistributionName(distribution),
      let payload = WindowsBundledWSLCLIPayload.load(from: self.payloadDirectory),
      let linuxHome = self.linuxHomeResolver(distribution),
      Self.isSafeLinuxHome(linuxHome)
    else { return nil }

    let wslExecutable = URL(fileURLWithPath: windowsDirectory)
      .appendingPathComponent("System32/wsl.exe", isDirectory: false).path
    guard
      let translatedDirectory = self.translatedPayloadDirectory(
        payload.directory,
        distribution: distribution,
        wslExecutable: wslExecutable)
    else { return nil }

    let destination = Self.destination(
      linuxHome: linuxHome,
      version: payload.version)
    guard
      !self.isSymbolicLink(
        destination.root,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.resourceBundle,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.executable,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.executableChecksum,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.stagingLauncher,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.stagingLauncherChecksum,
        distribution: distribution,
        wslExecutable: wslExecutable),
      !self.isSymbolicLink(
        destination.versionFile,
        distribution: distribution,
        wslExecutable: wslExecutable)
    else { return nil }
    if self.isComplete(
      destination: destination,
      payload: payload,
      distribution: distribution,
      wslExecutable: wslExecutable)
    {
      return destination.executable
    }

    for command in Self.installCommands(
      payloadLinuxDirectory: translatedDirectory,
      destination: destination)
    {
      guard
        self.run(
          command,
          distribution: distribution,
          wslExecutable: wslExecutable)?.exitCode == 0
      else { return nil }
    }
    return self.isComplete(
      destination: destination,
      payload: payload,
      distribution: distribution,
      wslExecutable: wslExecutable)
      ? destination.executable
      : nil
  }

  static func defaultPayloadDirectory(
    executableURL: URL? = nil
  ) -> URL? {
    (executableURL ?? Self.runningExecutableURL())?.deletingLastPathComponent()
      .appendingPathComponent("wsl-cli", isDirectory: true)
  }

  struct Destination: Equatable, Sendable {
    let root: String
    let executable: String
    let executableChecksum: String
    let versionFile: String
    let resourceBundle: String
    let stagingLauncher: String
    let stagingLauncherChecksum: String
  }

  static func destination(linuxHome: String, version: String) -> Destination {
    let root = "\(linuxHome)/.local/share/codexbar-windows/\(version)"
    return Destination(
      root: root,
      executable: "\(root)/CodexBarCLI",
      executableChecksum: "\(root)/CodexBarCLI.sha256",
      versionFile: "\(root)/VERSION",
      resourceBundle: "\(root)/CodexBar_CodexBarCore.bundle",
      stagingLauncher: "\(root)/CodexBarStagingLauncher",
      stagingLauncherChecksum: "\(root)/CodexBarStagingLauncher.sha256")
  }

  static func installCommands(
    payloadLinuxDirectory: String,
    destination: Destination
  ) -> [[String]] {
    let sourceExecutable = "\(payloadLinuxDirectory)/CodexBarCLI"
    let sourceExecutableChecksum = "\(payloadLinuxDirectory)/CodexBarCLI.sha256"
    let sourceVersion = "\(payloadLinuxDirectory)/VERSION"
    let sourceResources = "\(payloadLinuxDirectory)/CodexBar_CodexBarCore.bundle/."
    let sourceLauncher = "\(payloadLinuxDirectory)/CodexBarStagingLauncher"
    let sourceLauncherChecksum = "\(payloadLinuxDirectory)/CodexBarStagingLauncher.sha256"
    let temporaryExecutable = "\(destination.root)/.CodexBarCLI.installing"
    let temporaryExecutableChecksum = "\(destination.root)/.CodexBarCLI.sha256.installing"
    let temporaryVersion = "\(destination.root)/.VERSION.installing"
    let temporaryLauncher = "\(destination.root)/.CodexBarStagingLauncher.installing"
    let temporaryLauncherChecksum = "\(destination.root)/.CodexBarStagingLauncher.sha256.installing"
    return [
      ["/usr/bin/mkdir", "-p", destination.root, destination.resourceBundle],
      ["/usr/bin/chmod", "700", destination.root],
      ["/usr/bin/cp", "--", sourceExecutable, temporaryExecutable],
      ["/usr/bin/chmod", "500", temporaryExecutable],
      ["/usr/bin/mv", "-f", "--", temporaryExecutable, destination.executable],
      ["/usr/bin/cp", "--", sourceExecutableChecksum, temporaryExecutableChecksum],
      ["/usr/bin/chmod", "400", temporaryExecutableChecksum],
      [
        "/usr/bin/mv", "-f", "--", temporaryExecutableChecksum,
        destination.executableChecksum,
      ],
      ["/usr/bin/cp", "--", sourceLauncher, temporaryLauncher],
      ["/usr/bin/chmod", "500", temporaryLauncher],
      ["/usr/bin/mv", "-f", "--", temporaryLauncher, destination.stagingLauncher],
      ["/usr/bin/cp", "--", sourceLauncherChecksum, temporaryLauncherChecksum],
      ["/usr/bin/chmod", "400", temporaryLauncherChecksum],
      [
        "/usr/bin/mv", "-f", "--", temporaryLauncherChecksum,
        destination.stagingLauncherChecksum,
      ],
      ["/usr/bin/cp", "-R", "--", sourceResources, destination.resourceBundle],
      ["/usr/bin/chmod", "-R", "u=rwX,go=", destination.resourceBundle],
      ["/usr/bin/cp", "--", sourceVersion, temporaryVersion],
      ["/usr/bin/chmod", "400", temporaryVersion],
      ["/usr/bin/mv", "-f", "--", temporaryVersion, destination.versionFile],
    ]
  }

  static func decodedAbsoluteLinuxPath(_ data: Data) -> String? {
    // swiftlint:disable:next optional_data_string_conversion
    let decoded = String(decoding: data, as: UTF8.self)
    let value =
      decoded
      .components(separatedBy: .newlines).first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard value.hasPrefix("/"), value.utf8.count <= 4096,
      !value.unicodeScalars.contains(where: { $0.value < 32 })
    else { return nil }
    return value.hasSuffix("/") ? String(value.dropLast()) : value
  }

  private func translatedPayloadDirectory(
    _ directory: URL,
    distribution: String,
    wslExecutable: String
  ) -> String? {
    guard
      let result = self.run(
        ["/usr/bin/wslpath", "-a", "-u", directory.path],
        distribution: distribution,
        wslExecutable: wslExecutable),
      result.exitCode == 0
    else { return nil }
    return Self.decodedAbsoluteLinuxPath(result.standardOutput)
  }

  private func isComplete(
    destination: Destination,
    payload: WindowsBundledWSLCLIPayload,
    distribution: String,
    wslExecutable: String
  ) -> Bool {
    let checks = [
      ["/usr/bin/test", "-x", destination.executable],
      ["/usr/bin/test", "-x", destination.stagingLauncher],
      ["/usr/bin/test", "-d", destination.resourceBundle],
    ]
    guard
      checks.allSatisfy({ command in
        self.run(command, distribution: distribution, wslExecutable: wslExecutable)?.exitCode == 0
      }),
      let result = self.run(
        ["/usr/bin/cat", destination.versionFile],
        distribution: distribution,
        wslExecutable: wslExecutable),
      result.exitCode == 0
    else { return false }
    // swiftlint:disable:next optional_data_string_conversion
    let installedVersion = String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      installedVersion == payload.version,
      let executableExpectedResult = self.run(
        ["/usr/bin/cat", destination.executableChecksum],
        distribution: distribution,
        wslExecutable: wslExecutable),
      executableExpectedResult.exitCode == 0,
      let executableActualResult = self.run(
        ["/usr/bin/sha256sum", destination.executable],
        distribution: distribution,
        wslExecutable: wslExecutable),
      executableActualResult.exitCode == 0,
      let expectedExecutable = Self.checksumValue(executableExpectedResult.standardOutput),
      let actualExecutable = Self.checksumValue(executableActualResult.standardOutput),
      expectedExecutable == payload.executableChecksumValue,
      actualExecutable == payload.executableChecksumValue,
      let launcherExpectedResult = self.run(
        ["/usr/bin/cat", destination.stagingLauncherChecksum],
        distribution: distribution,
        wslExecutable: wslExecutable),
      launcherExpectedResult.exitCode == 0,
      let launcherActualResult = self.run(
        ["/usr/bin/sha256sum", destination.stagingLauncher],
        distribution: distribution,
        wslExecutable: wslExecutable),
      launcherActualResult.exitCode == 0,
      let expected = Self.checksumValue(launcherExpectedResult.standardOutput),
      let actual = Self.checksumValue(launcherActualResult.standardOutput),
      expected == payload.stagingLauncherChecksumValue,
      actual == payload.stagingLauncherChecksumValue
    else { return false }
    return true
  }

  static func checksumValue(_ data: Data) -> String? {
    // swiftlint:disable:next optional_data_string_conversion
    let decoded = String(decoding: data, as: UTF8.self)
    let line =
      decoded
      .components(separatedBy: .newlines).first ?? ""
    guard let token = line.split(whereSeparator: \.isWhitespace).first else { return nil }
    let value = String(token).lowercased()
    guard value.utf8.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
    return value
  }

  private func isSymbolicLink(
    _ path: String,
    distribution: String,
    wslExecutable: String
  ) -> Bool {
    guard
      let result = self.run(
        ["/usr/bin/test", "-L", path],
        distribution: distribution,
        wslExecutable: wslExecutable)
    else { return true }
    return result.exitCode == 0
  }

  private func run(
    _ command: [String],
    distribution: String,
    wslExecutable: String
  ) -> WindowsHiddenProcessResult? {
    self.commandRunner(
      wslExecutable,
      ["-d", distribution, "--"] + command)
  }

  static func isSafeLinuxHome(_ value: String) -> Bool {
    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 2, components[0] == "home" else { return false }
    let username = components[1]
    return !username.isEmpty && username != "." && username != ".."
      && !username.unicodeScalars.contains(where: { $0.value < 32 })
  }

  private static func runningExecutableURL() -> URL? {
    var capacity = 512
    while capacity <= 32_768 {
      var buffer = [WCHAR](repeating: 0, count: capacity)
      let length = buffer.withUnsafeMutableBufferPointer {
        GetModuleFileNameW(nil, $0.baseAddress, DWORD($0.count))
      }
      guard length > 0 else { return nil }
      if Int(length) < capacity - 1 {
        return URL(
          fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF16.self),
          isDirectory: false)
      }
      capacity *= 2
    }
    return nil
  }
}
