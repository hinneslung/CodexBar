import Foundation
import WinSDK

struct WindowsWSLDistribution: Equatable, Sendable {
  let name: String
  let defaultUID: UInt32
}

/// Reads WSL's own registration metadata without opening a console or launching a distribution.
enum WindowsWSLDistributionRegistry {
  private static let lxssPath = #"Software\Microsoft\Windows\CurrentVersion\Lxss"#
  private static let readAccess = REGSAM(0x0000_0009)

  static func names() -> [String] {
    self.distributions().map(\.name).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  static func distributions() -> [WindowsWSLDistribution] {
    var lxssKey: HKEY?
    let opened = WindowsWideString.withPointer(self.lxssPath) { path in
      RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, self.readAccess, &lxssKey)
    }
    guard opened == LSTATUS(ERROR_SUCCESS), let lxssKey else { return [] }
    defer { RegCloseKey(lxssKey) }

    var results: [WindowsWSLDistribution] = []
    var index: DWORD = 0
    while results.count < 32 {
      var name = [WCHAR](repeating: 0, count: 256)
      var nameLength = DWORD(name.count)
      let status = name.withUnsafeMutableBufferPointer { buffer in
        RegEnumKeyExW(lxssKey, index, buffer.baseAddress, &nameLength, nil, nil, nil, nil)
      }
      guard status != LSTATUS(ERROR_NO_MORE_ITEMS) else { break }
      index += 1
      guard status == LSTATUS(ERROR_SUCCESS) else { continue }

      let subkeyName = String(decoding: name.prefix(Int(nameLength)), as: UTF16.self)
      guard let key = self.openSubkey(parent: lxssKey, name: subkeyName) else { continue }
      defer { RegCloseKey(key) }
      guard self.dwordValue(key: key, name: "Version") == 2,
        let distributionName = self.stringValue(key: key, name: "DistributionName"),
        self.isSafeDistributionName(distributionName),
        let defaultUID = self.dwordValue(key: key, name: "DefaultUid")
      else { continue }
      results.append(.init(name: distributionName, defaultUID: defaultUID))
    }
    return results
  }

  private static func openSubkey(parent: HKEY, name: String) -> HKEY? {
    var key: HKEY?
    let status = WindowsWideString.withPointer(name) { value in
      RegOpenKeyExW(parent, value, 0, self.readAccess, &key)
    }
    return status == LSTATUS(ERROR_SUCCESS) ? key : nil
  }

  private static func dwordValue(key: HKEY, name: String) -> DWORD? {
    var type: DWORD = 0
    var value: DWORD = 0
    var size = DWORD(MemoryLayout<DWORD>.size)
    let status = WindowsWideString.withPointer(name) { valueName in
      withUnsafeMutableBytes(of: &value) { bytes in
        RegQueryValueExW(
          key, valueName, nil, &type, bytes.bindMemory(to: BYTE.self).baseAddress, &size)
      }
    }
    return status == LSTATUS(ERROR_SUCCESS) && type == DWORD(REG_DWORD) ? value : nil
  }

  private static func stringValue(key: HKEY, name: String) -> String? {
    var type: DWORD = 0
    var size: DWORD = 0
    let measured = WindowsWideString.withPointer(name) { valueName in
      RegQueryValueExW(key, valueName, nil, &type, nil, &size)
    }
    guard measured == LSTATUS(ERROR_SUCCESS), type == DWORD(REG_SZ), size > 0 else { return nil }

    var value = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
    let status = WindowsWideString.withPointer(name) { valueName in
      value.withUnsafeMutableBytes { bytes in
        RegQueryValueExW(
          key, valueName, nil, &type, bytes.bindMemory(to: BYTE.self).baseAddress, &size)
      }
    }
    guard status == LSTATUS(ERROR_SUCCESS) else { return nil }
    let result = String(decoding: value.prefix { $0 != 0 }, as: UTF16.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  static func isSafeDistributionName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
    return !trimmed.contains("\\") && !trimmed.contains("/")
      && !trimmed.unicodeScalars.contains { $0.value < 32 }
  }
}

enum WindowsWSLDefaultUserHome {
  static func directory(distributionName: String, fileManager: FileManager = .default) -> URL? {
    guard
      let distribution = WindowsWSLDistributionRegistry.distributions().first(where: {
        $0.name.caseInsensitiveCompare(distributionName) == .orderedSame
      }),
      distribution.defaultUID != 0
    else { return nil }
    let root = URL(fileURLWithPath: #"\\wsl.localhost"#, isDirectory: true)
      .appendingPathComponent(distribution.name, isDirectory: true)
    return self.directory(
      distributionRoot: root,
      defaultUID: distribution.defaultUID,
      fileManager: fileManager)
  }

  static func directory(
    distributionRoot: URL,
    defaultUID: UInt32,
    fileManager _: FileManager = .default
  ) -> URL? {
    guard defaultUID != 0 else { return nil }
    let passwdURL =
      distributionRoot
      .appendingPathComponent("etc", isDirectory: true)
      .appendingPathComponent("passwd", isDirectory: false)
    guard let data = try? Data(contentsOf: passwdURL),
      let contents = String(data: data, encoding: .utf8)
    else { return nil }

    let username = contents.split(whereSeparator: \.isNewline)
      .prefix(4096)
      .compactMap { line -> String? in
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 6, UInt32(fields[2]) == defaultUID else { return nil }
        let components = fields[5].split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "home" else { return nil }
        let value = String(components[1])
        guard self.isSafePathComponent(value) else { return nil }
        return value
      }
      .first
    guard let username else { return nil }
    return
      distributionRoot
      .appendingPathComponent("home", isDirectory: true)
      .appendingPathComponent(username, isDirectory: true)
  }

  static func openCodeAuthURL(distributionName: String) -> URL? {
    self.directory(distributionName: distributionName)?
      .appendingPathComponent(".local", isDirectory: true)
      .appendingPathComponent("share", isDirectory: true)
      .appendingPathComponent("opencode", isDirectory: true)
      .appendingPathComponent("auth.json", isDirectory: false)
  }

  static func linuxPath(distributionName: String) -> String? {
    guard let directory = self.directory(distributionName: distributionName) else { return nil }
    let username = directory.lastPathComponent
    guard self.isSafePathComponent(username) else { return nil }
    return "/home/\(username)"
  }

  private static func isSafePathComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("\\")
      && !value.contains("/") && !value.unicodeScalars.contains { $0.value < 32 }
  }
}
