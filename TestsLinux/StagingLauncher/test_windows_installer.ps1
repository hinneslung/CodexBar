[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][string] $Archive,
    [Parameter(Mandatory)][ValidateSet('x86_64', 'arm64')][string] $AssetArchitecture,
    [string] $DiagnosticsDirectory,
    [switch] $TestIdentity
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../Scripts/windows_installer_payload.ps1')
$expected = if ($AssetArchitecture -eq 'x86_64') { 'X64' } else { 'Arm64' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne $expected) {
    throw 'Installer lifecycle must execute on the matching native architecture.'
}
$product = if ($TestIdentity) { 'CodexBar Installer QA' } else { 'CodexBar' }
$appId = if ($TestIdentity) { 'CodexBar.Windows.Installer.QA' } else { 'CodexBar.Windows' }
$taskName = if ($TestIdentity) { 'CodexBar Installer QA Autostart' } else { 'CodexBar Autostart' }
$registryPath = "Software\Microsoft\Windows\CurrentVersion\Uninstall\${appId}_is1"
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
if ($null -ne $registry.OpenSubKey($registryPath)) { throw 'Existing installation identity; refusing lifecycle test.' }
if (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw 'Existing startup task; refusing lifecycle test.'
}
$programs = [Environment]::GetFolderPath('Programs')
$shortcut = Join-Path $programs "$product\$product.lnk"
if (Test-Path -LiteralPath (Join-Path $programs $product)) { throw 'Existing Start menu group; refusing lifecycle test.' }
$qaBase = Join-Path ([IO.Path]::GetTempPath()) 'CodexBar/qa'
[IO.Directory]::CreateDirectory($qaBase) | Out-Null
$work = Join-Path $qaBase ('installer-lifecycle-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($work) | Out-Null
if (-not $DiagnosticsDirectory) { $DiagnosticsDirectory = Join-Path $work 'diagnostics' }
if (Test-Path -LiteralPath $DiagnosticsDirectory) { throw 'Diagnostics directory must be new.' }
[IO.Directory]::CreateDirectory($DiagnosticsDirectory) | Out-Null
Write-Host "Installer diagnostics: $DiagnosticsDirectory"
$installDirectory = Join-Path $work 'installed'
$sourceDirectory = Join-Path $work 'source'
$exe = Join-Path $installDirectory 'CodexBar.exe'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$savedEnvironment = @{}
foreach ($name in @('LOCALAPPDATA', 'CODEXBAR_WINDOWS_OFFLINE', 'PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$appProcess = $null
$taskCreated = $false
$installCount = 0
$uninstallCount = 0
$payloadInstalled = $false
$lifecycleStage = 'prepare-payload'

function Write-LifecycleStage([string] $Name) {
    $script:lifecycleStage = $Name
    $line = "$([DateTime]::UtcNow.ToString('o')) $Name"
    Write-Host "Installer stage: $Name"
    try {
        [IO.File]::AppendAllText((Join-Path $DiagnosticsDirectory 'stages.log'), "$line`n")
    } catch { Write-Warning "Could not write stage log: $($_.Exception.Message)" -WarningAction Continue }
}
function Write-LifecycleFailure([Management.Automation.ErrorRecord] $Failure, [string] $Kind) {
    # Report before cleanup can replace the primary exception. Diagnostics must not mask it either.
    $report = "Kind: $Kind`nStage: $lifecycleStage`n$($Failure.Exception.Message)`n" +
        "$($Failure.InvocationInfo.PositionMessage)`n$($Failure.ScriptStackTrace)"
    Write-Host $report
    try {
        [IO.File]::WriteAllText((Join-Path $DiagnosticsDirectory "$Kind-failure.txt"), $report)
    } catch { Write-Warning "Could not write $Kind failure report: $($_.Exception.Message)" -WarningAction Continue }
}

function Invoke-InstallerProcess([string] $Path, [string[]] $Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(120000)) {
        Stop-Process -Id $process.Id -Force
        throw "Installer exceeded the lifecycle deadline at $lifecycleStage."
    }
    Write-Host "Installer stage $lifecycleStage exited with code $($process.ExitCode)."
    if ($process.ExitCode -ne 0) { throw "Installer lifecycle failed at ${lifecycleStage}: $($process.ExitCode)" }
}
function Install-Payload {
    $script:installCount++
    # Retain cleanup responsibility even if setup exits after a partial install.
    $script:payloadInstalled = $true
    Write-LifecycleStage "setup-$installCount"
    $log = Join-Path $DiagnosticsDirectory "setup-$installCount.log"
    Invoke-InstallerProcess $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        '/CLOSEAPPLICATIONS', '/RESTARTEXITCODE=3010', "/DIR=`"$installDirectory`"", "/LOG=`"$log`"")
}
function Uninstall-Payload {
    $script:uninstallCount++
    Write-LifecycleStage "uninstall-$uninstallCount"
    $log = Join-Path $DiagnosticsDirectory "uninstall-$uninstallCount.log"
    Invoke-InstallerProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"")
    # Inno may delete its executable asynchronously after success. Its continued existence is
    # not evidence of an installed payload and must not trigger a second uninstall in finally.
    $script:payloadInstalled = $false
}
function Assert-Payload {
    foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($sourceDirectory, $file.FullName)
        $installed = Join-Path $installDirectory $relative
        if (-not (Test-Path -LiteralPath $installed) -or
            (Get-FileHash -LiteralPath $file.FullName).Hash -cne (Get-FileHash -LiteralPath $installed).Hash) {
            throw "Installed payload differs: $relative"
        }
    }
    if (-not (Test-Path -LiteralPath $shortcut)) { throw 'Start menu shortcut is missing.' }
    $key = $registry.OpenSubKey($registryPath)
    if ($null -eq $key) { throw 'Per-user uninstall registration is missing.' }
    try {
        if ([IO.Path]::GetFullPath($key.GetValue('InstallLocation')).TrimEnd('\') -ine $installDirectory) {
            throw 'Uninstall registration points to another location.'
        }
    } finally { $key.Dispose() }
}
function Set-FixtureTask([string] $Target, [switch] $Multiple) {
    $actions = @(New-ScheduledTaskAction -Execute $Target)
    if ($Multiple) { $actions += New-ScheduledTaskAction -Execute (Join-Path $work 'other.exe') }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath '\' -TaskName $taskName -Action $actions -Principal $principal -Force | Out-Null
    $script:taskCreated = $true
}
function Assert-PreservedData {
    if ((Get-Content -LiteralPath (Join-Path $installDirectory 'user-added.txt') -Raw) -cne 'user-added-canary' -or
        (Get-Content -LiteralPath (Join-Path $dataDirectory 'Credentials/fixture.bin') -Raw) -cne 'synthetic-vault-canary' -or
        (Get-FileHash -LiteralPath $config).Hash -cne $configHash) { throw 'User data changed.' }
}
try {
    Write-LifecycleStage 'prepare-payload'
    Expand-VerifiedWindowsPayload -Archive $Archive -Architecture $AssetArchitecture -Destination $sourceDirectory
    $env:LOCALAPPDATA = Join-Path $work 'localappdata'
    $env:CODEXBAR_WINDOWS_OFFLINE = '1'
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $dataDirectory = Join-Path $env:LOCALAPPDATA 'CodexBar'
    [IO.Directory]::CreateDirectory((Join-Path $dataDirectory 'Credentials')) | Out-Null
    $config = Join-Path $dataDirectory 'config.json'
    [IO.File]::WriteAllText($config, '{"schemaVersion":7,"runAtStartup":false,"providers":[]}')
    [IO.File]::WriteAllText((Join-Path $dataDirectory 'Credentials/fixture.bin'), 'synthetic-vault-canary')
    Install-Payload
    Assert-Payload
    if (Get-Process CodexBar -ErrorAction SilentlyContinue | Where-Object Path -eq $exe) {
        throw 'Silent installation unexpectedly launched the app.'
    }
    Write-LifecycleStage 'installed-app-smoke'
    $appProcess = Start-Process -FilePath $exe -WorkingDirectory $installDirectory -PassThru -WindowStyle Hidden
    if ($appProcess.WaitForExit(5000)) { throw "Installed app exited: $($appProcess.ExitCode)" }
    # Smoke startup may migrate synthetic defaults; preserve the resulting state across upgrade/uninstall.
    $configHash = (Get-FileHash -LiteralPath $config).Hash
    [IO.File]::WriteAllText((Join-Path $installDirectory 'user-added.txt'), 'user-added-canary')
    [IO.File]::WriteAllText((Join-Path $installDirectory 'VERSION'), 'replace-this-old-version')
    Install-Payload
    Assert-Payload
    Assert-PreservedData
    $appProcess.Refresh()
    if (-not $appProcess.HasExited) { throw 'Reinstall did not close the installed app.' }
    Write-LifecycleStage 'running-app-uninstall-guard'
    Set-FixtureTask (Join-Path $work 'portable/CodexBar.exe')
    $appProcess = Start-Process -FilePath $exe -WorkingDirectory $installDirectory -PassThru -WindowStyle Hidden
    if ($appProcess.WaitForExit(5000)) { throw 'Installed app did not stay running for uninstall guard test.' }
    $guardLog = Join-Path $DiagnosticsDirectory 'uninstall-guard.log'
    $blocked = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        "/LOG=`"$guardLog`"") `
        -PassThru -WindowStyle Hidden
    if (-not $blocked.WaitForExit(30000)) { Stop-Process -Id $blocked.Id -Force; throw 'Uninstall guard hung.' }
    Write-Host "Uninstall guard exited with code $($blocked.ExitCode) (nonzero expected)."
    if ($blocked.ExitCode -eq 0) { throw 'Uninstall accepted a running installed app.' }
    Assert-Payload
    if (-not (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Blocked uninstall changed startup registration.'
    }
    Stop-Process -Id $appProcess.Id -Force
    $appProcess.WaitForExit()
    Uninstall-Payload
    Assert-PreservedData
    if (-not (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Uninstall removed another copy startup task.'
    }
    Install-Payload
    Set-FixtureTask $exe -Multiple
    Uninstall-Payload
    if (-not (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Uninstall removed a multi-action task.'
    }
    Install-Payload
    Set-FixtureTask $exe
    Uninstall-Payload
    Assert-PreservedData
    if (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw 'Uninstall did not remove the installed copy startup task.'
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File) {
        if (Test-Path -LiteralPath (Join-Path $installDirectory ([IO.Path]::GetRelativePath($sourceDirectory, $file.FullName)))) {
            throw 'Uninstall left installer-owned payload files.'
        }
    }
    if ((Test-Path -LiteralPath $shortcut) -or $null -ne $registry.OpenSubKey($registryPath)) {
        throw 'Uninstall left registration or shortcut.'
    }
    Write-LifecycleStage 'complete'
    Write-Host "Installer lifecycle passed on $expected. Evidence: $work"
} catch {
    Write-LifecycleFailure $_ 'primary'
    throw
} finally {
    try {
        Write-LifecycleStage 'cleanup'
        if ($null -ne $appProcess -and -not $appProcess.HasExited) { Stop-Process -Id $appProcess.Id -Force }
        if ($payloadInstalled -and (Test-Path -LiteralPath $uninstaller)) { Uninstall-Payload }
    } catch {
        Write-LifecycleFailure $_ 'cleanup'
        throw
    } finally {
        try {
            if ($taskCreated) { Unregister-ScheduledTask -TaskPath '\' -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
        } finally {
            foreach ($name in $savedEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
            }
            $registry.Dispose()
        }
    }
}
