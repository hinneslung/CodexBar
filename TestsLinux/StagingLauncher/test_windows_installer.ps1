[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][string] $Archive,
    [Parameter(Mandatory)][ValidateSet('x86_64', 'arm64')][string] $AssetArchitecture,
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
$payloadInstalled = $false

function Invoke-InstallerProcess([string] $Path, [string[]] $Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(120000)) {
        Stop-Process -Id $process.Id -Force
        throw 'Installer exceeded the lifecycle deadline.'
    }
    if ($process.ExitCode -ne 0) { throw "Installer lifecycle failed: $($process.ExitCode)" }
}
function Install-Payload {
    $script:installCount++
    # Retain cleanup responsibility even if setup exits after a partial install.
    $script:payloadInstalled = $true
    Invoke-InstallerProcess $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        '/CLOSEAPPLICATIONS', '/RESTARTEXITCODE=3010', "/DIR=`"$installDirectory`"", "/LOG=`"$work\setup-$installCount.log`"")
}
function Uninstall-Payload {
    Invoke-InstallerProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$work\uninstall.log`"")
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
    Set-FixtureTask (Join-Path $work 'portable/CodexBar.exe')
    $appProcess = Start-Process -FilePath $exe -WorkingDirectory $installDirectory -PassThru -WindowStyle Hidden
    if ($appProcess.WaitForExit(5000)) { throw 'Installed app did not stay running for uninstall guard test.' }
    $blocked = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
        -PassThru -WindowStyle Hidden
    if (-not $blocked.WaitForExit(30000)) { Stop-Process -Id $blocked.Id -Force; throw 'Uninstall guard hung.' }
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
    Write-Host "Installer lifecycle passed on $expected. Evidence: $work"
} finally {
    try {
        if ($null -ne $appProcess -and -not $appProcess.HasExited) { Stop-Process -Id $appProcess.Id -Force }
        if ($payloadInstalled -and (Test-Path -LiteralPath $uninstaller)) { Uninstall-Payload }
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
