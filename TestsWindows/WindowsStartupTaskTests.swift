import XCTest

@testable import CodexBarWindows

final class WindowsStartupTaskTests: XCTestCase {
  func test_enableScriptRegistersCurrentUserTaskWithoutElevatingOrOpeningAConsole() {
    let script = WindowsStartupTask.enableScript(
      executablePath: "C:\\Apps\\CodexBar.exe",
      workingDirectory: "C:\\Apps")

    XCTAssertTrue(script.contains("New-ScheduledTaskAction -Execute 'C:\\Apps\\CodexBar.exe'"))
    XCTAssertTrue(script.contains("New-ScheduledTaskTrigger -AtLogOn -User $userId"))
    XCTAssertTrue(script.contains("-LogonType Interactive -RunLevel Limited"))
    XCTAssertTrue(script.contains("-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries"))
    XCTAssertTrue(script.contains("Register-ScheduledTask -TaskName 'CodexBar Autostart'"))
    XCTAssertFalse(script.contains("Highest"))
  }

  func test_scriptsEscapePowerShellValuesAndRemoveOnlyCodexBarTask() {
    XCTAssertEqual(WindowsStartupTask.powershellSingleQuoted("A'B"), "'A''B'")
    let disable = WindowsStartupTask.disableScript()
    XCTAssertTrue(disable.contains("Get-ScheduledTask -TaskName 'CodexBar Autostart'"))
    XCTAssertTrue(disable.contains("Unregister-ScheduledTask -TaskName 'CodexBar Autostart'"))
    XCTAssertTrue(disable.contains("-Confirm:$false"))
  }

  func test_statusScriptDetectsMovedApplicationAndTaskPolicyDrift() {
    let script = WindowsStartupTask.statusScript(
      executablePath: "C:\\Current\\CodexBar.exe",
      workingDirectory: "C:\\Current")

    XCTAssertTrue(script.contains("$action.Execute -ieq 'C:\\Current\\CodexBar.exe'"))
    XCTAssertTrue(script.contains("$action.WorkingDirectory -ieq 'C:\\Current'"))
    XCTAssertTrue(script.contains("$principal.RunLevel.ToString() -eq 'Limited'"))
    XCTAssertTrue(script.contains("'missing'"))
    XCTAssertTrue(script.contains("'repair'"))
  }
}
