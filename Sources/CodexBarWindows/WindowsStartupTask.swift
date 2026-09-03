import Foundation
import WinSDK

enum WindowsStartupTaskError: Error, Equatable, LocalizedError {
  case executableUnavailable
  case powershellUnavailable
  case commandFailed

  var errorDescription: String? {
    switch self {
    case .executableUnavailable:
      "CodexBar could not locate its executable."
    case .powershellUnavailable:
      "Windows PowerShell is unavailable."
    case .commandFailed:
      "Windows could not update the CodexBar startup task."
    }
  }
}

/// Owns the Task Scheduler integration used by the Windows "Run at startup" setting.
/// The task is registered for the current interactive user and never opens a console window.
enum WindowsStartupTask {
  static let taskName = "CodexBar Autostart"

  static func setEnabled(_ enabled: Bool) throws {
    let target = try Self.currentTarget()
    let script =
      enabled
      ? Self.enableScript(
        executablePath: target.executablePath, workingDirectory: target.workingDirectory)
      : Self.disableScript()
    _ = try Self.run(script)

    if enabled {
      let status = try Self.run(
        Self.statusScript(
          executablePath: target.executablePath,
          workingDirectory: target.workingDirectory))
      guard status.caseInsensitiveCompare("ok") == .orderedSame else {
        throw WindowsStartupTaskError.commandFailed
      }
    }
  }

  /// Re-registers a configured task after the application has moved or been upgraded in place.
  static func repairIfEnabled() {
    guard let target = try? Self.currentTarget(),
      let status = try? Self.run(
        Self.statusScript(
          executablePath: target.executablePath,
          workingDirectory: target.workingDirectory)),
      status.caseInsensitiveCompare("ok") != .orderedSame
    else {
      return
    }
    _ = try? Self.run(
      Self.enableScript(
        executablePath: target.executablePath,
        workingDirectory: target.workingDirectory))
  }

  static func enableScript(executablePath: String, workingDirectory: String) -> String {
    let executable = Self.powershellSingleQuoted(executablePath)
    let directory = Self.powershellSingleQuoted(workingDirectory)
    let name = Self.powershellSingleQuoted(Self.taskName)
    return
      "$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name; "
      + "$action = New-ScheduledTaskAction -Execute \(executable) -WorkingDirectory \(directory); "
      + "$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId; "
      + "$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive "
      + "-RunLevel Limited; "
      + "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries "
      + "-DontStopIfGoingOnBatteries; "
      + "Register-ScheduledTask -TaskName \(name) -Action $action -Trigger $trigger "
      + "-Principal $principal -Settings $settings -Force | Out-Null"
  }

  static func disableScript() -> String {
    let name = Self.powershellSingleQuoted(Self.taskName)
    return
      "$task = Get-ScheduledTask -TaskName \(name) -ErrorAction SilentlyContinue; "
      + "if ($null -ne $task) { Unregister-ScheduledTask -TaskName \(name) -Confirm:$false }"
  }

  static func statusScript(executablePath: String, workingDirectory: String) -> String {
    let executable = Self.powershellSingleQuoted(executablePath)
    let directory = Self.powershellSingleQuoted(workingDirectory)
    let name = Self.powershellSingleQuoted(Self.taskName)
    return
      "$task = Get-ScheduledTask -TaskName \(name) -ErrorAction SilentlyContinue; "
      + "if ($null -eq $task) { 'missing' } else { "
      + "$action = $task.Actions | Select-Object -First 1; $settings = $task.Settings; "
      + "$principal = $task.Principal; "
      + "$matches = ($null -ne $action) -and ($action.Execute -ieq \(executable)) -and "
      + "([string]::IsNullOrWhiteSpace($action.Arguments)) -and "
      + "($action.WorkingDirectory -ieq \(directory)) -and "
      + "($principal.RunLevel.ToString() -eq 'Limited') -and "
      + "($settings.DisallowStartIfOnBatteries -eq $false) -and "
      + "($settings.StopIfGoingOnBatteries -eq $false); "
      + "if ($matches) { 'ok' } else { 'repair' } }"
  }

  static func powershellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
  }

  private static func run(_ script: String) throws -> String {
    let executable = try Self.powershellExecutablePath()
    let result: WindowsHiddenProcessResult
    do {
      result = try WindowsHiddenProcessRunner.run(
        executablePath: executable,
        arguments: [
          "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script,
        ],
        timeout: 15,
        maximumOutputBytes: 64 * 1024)
    } catch {
      throw WindowsStartupTaskError.commandFailed
    }
    guard result.exitCode == 0 else { throw WindowsStartupTaskError.commandFailed }
    return String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func powershellExecutablePath() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["SystemRoot"] ?? environment["WINDIR"] else {
      throw WindowsStartupTaskError.powershellUnavailable
    }
    let path = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe", isDirectory: false)
      .path
    guard FileManager.default.fileExists(atPath: path) else {
      throw WindowsStartupTaskError.powershellUnavailable
    }
    return path
  }

  private static func currentTarget() throws -> (executablePath: String, workingDirectory: String) {
    guard let executablePath = Self.runningExecutablePath(),
      let separator = executablePath.lastIndex(where: { $0 == "\\" || $0 == "/" })
    else {
      throw WindowsStartupTaskError.executableUnavailable
    }
    return (executablePath, String(executablePath[..<separator]))
  }

  private static func runningExecutablePath() -> String? {
    var capacity = 512
    while capacity <= 32_768 {
      var buffer = [WCHAR](repeating: 0, count: capacity)
      let length = buffer.withUnsafeMutableBufferPointer {
        GetModuleFileNameW(nil, $0.baseAddress, DWORD($0.count))
      }
      guard length > 0 else { return nil }
      if Int(length) < capacity - 1 {
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
      }
      capacity *= 2
    }
    return nil
  }
}
