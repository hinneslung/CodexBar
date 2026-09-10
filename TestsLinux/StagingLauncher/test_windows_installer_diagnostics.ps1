$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load only production helpers: no installer, registry, task, app or live data access.
$tokens = $null
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'test_windows_installer.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Lifecycle script does not parse.' }
$definitions = @{}
foreach ($name in @('Write-LifecycleStage', 'Write-LifecycleFailure', 'Install-Payload',
    'Uninstall-Payload', 'Invoke-InstallerProcess')) {
    $definition = $tree.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing production function: $name" }
    $definitions[$name] = $definition.Extent.Text
    . ([scriptblock]::Create($definition.Extent.Text))
}
$qaBase = Join-Path ([IO.Path]::GetTempPath()) 'CodexBar/qa'
$fixtureRoot = Join-Path $qaBase ('installer-diagnostics-test-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$DiagnosticsDirectory = $fixtureRoot
$Installer = 'synthetic-setup.exe'
$uninstaller = 'synthetic-uninstall.exe'
$installDirectory = 'synthetic-installation'
$installCount = 0
$uninstallCount = 0
$payloadInstalled = $false
$calls = [Collections.Generic.List[object]]::new()
function Invoke-InstallerProcess([string] $Path, [string[]] $Arguments) {
    $calls.Add(@{ Path = $Path; Arguments = $Arguments })
}
try {
    Install-Payload
    Uninstall-Payload
    Install-Payload
    Uninstall-Payload
    $expectedLogs = @('setup-1.log', 'uninstall-1.log', 'setup-2.log', 'uninstall-2.log')
    for ($i = 0; $i -lt $calls.Count; $i++) {
        $log = Join-Path $DiagnosticsDirectory $expectedLogs[$i]
        if (@($calls[$i].Arguments | Where-Object { $_ -ceq "/LOG=`"$log`"" }).Count -ne 1) {
            throw 'An installer operation reused or lost its diagnostic log.'
        }
    }
    if ($calls.Count -ne 4 -or $payloadInstalled) { throw 'Diagnostics changed cleanup state.' }
    $stages = Get-Content -LiteralPath (Join-Path $DiagnosticsDirectory 'stages.log') -Raw
    foreach ($name in @('setup-1', 'uninstall-1', 'setup-2', 'uninstall-2')) {
        if (-not $stages.Contains($name)) { throw 'Missing operation stage.' }
    }
    try { throw 'synthetic primary error' } catch { Write-LifecycleFailure $_ 'primary' }
    Write-LifecycleStage 'cleanup'
    try { throw 'synthetic cleanup error' } catch { Write-LifecycleFailure $_ 'cleanup' }
    $primary = Get-Content -LiteralPath (Join-Path $DiagnosticsDirectory 'primary-failure.txt') -Raw
    $cleanup = Get-Content -LiteralPath (Join-Path $DiagnosticsDirectory 'cleanup-failure.txt') -Raw
    if (-not $primary.Contains('synthetic primary error') -or -not $primary.Contains('Stage: uninstall-2') -or
        $primary.Contains('synthetic cleanup error') -or -not $cleanup.Contains('synthetic cleanup error') -or
        -not $cleanup.Contains('Stage: cleanup')) { throw 'Primary and cleanup evidence were not preserved separately.' }

    # Use the real wrapper with an inert process object for exit and timeout reporting.
    . ([scriptblock]::Create($definitions['Invoke-InstallerProcess']))
    $fakeExitCode = 1
    $fakeWait = $true
    $fakeStopped = $false
    function Start-Process {
        $process = [pscustomobject]@{ Id = 123; ExitCode = $fakeExitCode }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($milliseconds)
            if ($milliseconds -ne 120000) { throw 'Process deadline changed.' }
            return $fakeWait
        }
        return $process
    }
    function Stop-Process { $script:fakeStopped = $true }
    Write-LifecycleStage 'setup-3'
    $message = $null
    try { Invoke-InstallerProcess 'synthetic.exe' @() } catch { $message = $_.Exception.Message }
    if ($message -cne 'Installer lifecycle failed at setup-3: 1') { throw 'Exit failure lacks stage/code.' }
    $fakeExitCode = 0
    Invoke-InstallerProcess 'synthetic.exe' @()
    $fakeWait = $false
    $message = $null
    try { Invoke-InstallerProcess 'synthetic.exe' @() } catch { $message = $_.Exception.Message }
    if ($message -cne 'Installer exceeded the lifecycle deadline at setup-3.' -or -not $fakeStopped) {
        throw 'Timeout behavior or stage reporting changed.'
    }
    $DiagnosticsDirectory = Join-Path $fixtureRoot 'missing/child'
    Write-LifecycleStage 'unwritable-diagnostics'
    try { throw 'original error' } catch { Write-LifecycleFailure $_ 'primary' }
    Write-Host 'Installer diagnostics tests passed (unique logs, separate errors, exits, timeout, write failure).'
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixtureRoot)) -ne [IO.Path]::GetFullPath($qaBase)) {
        throw 'Unsafe fixture cleanup path.'
    }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
