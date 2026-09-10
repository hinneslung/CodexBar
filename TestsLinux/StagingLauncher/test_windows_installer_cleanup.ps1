$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exercise the production state transitions without touching installers, user data or tasks.
$source = Join-Path $PSScriptRoot 'test_windows_installer.ps1'
$tokens = $null
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Lifecycle script does not parse.' }
foreach ($name in @('Install-Payload', 'Uninstall-Payload')) {
    $definition = $tree.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing production function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$Installer = 'synthetic-setup.exe'
$uninstaller = 'synthetic-uninstall.exe'
$work = 'synthetic-work'
$installDirectory = 'synthetic-installation'
$installCount = 0
$uninstallCount = 0
$DiagnosticsDirectory = 'synthetic-diagnostics'
$payloadInstalled = $false
$failProcess = $false
function Write-LifecycleStage([string] $Name) {}
function Invoke-InstallerProcess([string] $Path, [string[]] $Arguments) {
    if ($failProcess) { throw 'Synthetic process failure' }
}
Install-Payload
if (-not $payloadInstalled) { throw 'Successful setup must retain cleanup responsibility.' }
Uninstall-Payload
if ($payloadInstalled) { throw 'Successful uninstall must prevent duplicate cleanup.' }
$failProcess = $true
try { Install-Payload } catch { if ($_.Exception.Message -ne 'Synthetic process failure') { throw } }
if (-not $payloadInstalled) { throw 'Failed setup must retain partial-install cleanup responsibility.' }
try { Uninstall-Payload } catch { if ($_.Exception.Message -ne 'Synthetic process failure') { throw } }
if (-not $payloadInstalled) { throw 'Failed uninstall must retain cleanup responsibility.' }
$failProcess = $false
Uninstall-Payload
if ($payloadInstalled) { throw 'Successful cleanup retry must clear responsibility.' }
Write-Host 'Installer cleanup state tests passed (5 transitions).'
