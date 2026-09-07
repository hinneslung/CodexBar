[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Archive,
    [Parameter(Mandatory)][ValidateSet('x86_64', 'arm64')][string] $AssetArchitecture,
    [Parameter(Mandatory)][string] $SafeRefName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$wrapper = Join-Path $PSScriptRoot '../../Scripts/package_windows_installer.ps1'
$base = Join-Path ([IO.Path]::GetTempPath()) 'CodexBar/qa'
[IO.Directory]::CreateDirectory($base) | Out-Null
$work = Join-Path $base ('installer-negative-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($work) | Out-Null
$defaultArgs = @{ Archive = $Archive; AssetArchitecture = $AssetArchitecture; SafeRefName = $SafeRefName;
    OutputDirectory = $work; ValidateOnly = $true }
function Assert-Rejected([hashtable] $Arguments, [string] $Label, [string] $ExpectedMessage) {
    $rejected = $false
    try { & $wrapper @Arguments } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            throw "Wrong rejection for ${Label}: $($_.Exception.Message)"
        }
        $rejected = $true
    }
    if (-not $rejected) { throw "Packaging accepted $Label." }
    Write-Host "Rejected $Label"
}
function Write-Checksum([string] $Path) {
    $hash = (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$Path.sha256", "$hash  $([IO.Path]::GetFileName($Path))`n")
}
try {
    & $wrapper @defaultArgs
    $argsCopy = $defaultArgs.Clone(); $argsCopy.SafeRefName = '../invalid'
    Assert-Rejected $argsCopy 'invalid ref' 'SafeRefName'
    $version = Join-Path $work 'version.env'
    [IO.File]::WriteAllText($version, "MARKETING_VERSION=1.2.999999`nBUILD_NUMBER=1`n")
    $argsCopy = $defaultArgs.Clone(); $argsCopy.VersionFile = $version
    Assert-Rejected $argsCopy 'invalid Windows version' 'Version component exceeds Windows limits'
    $argsCopy = $defaultArgs.Clone()
    $argsCopy.AssetArchitecture = if ($AssetArchitecture -eq 'x86_64') { 'arm64' } else { 'x86_64' }
    Assert-Rejected $argsCopy 'mismatched payload architecture' 'PE architecture mismatch|Missing payload item: vcruntime140_1.dll'
    $output = Join-Path $work "CodexBar-$SafeRefName-windows-$AssetArchitecture-setup.exe"
    [IO.File]::WriteAllText($output, 'existing-output-canary')
    Assert-Rejected $defaultArgs 'output overwrite' 'Refusing to overwrite installer output'
    if ((Get-Content -LiteralPath $output -Raw) -cne 'existing-output-canary') { throw 'Output was overwritten.' }
    Remove-Item -LiteralPath $output
    $outsideCanary = Join-Path $work 'outside-canary.txt'
    foreach ($entryName in @('../outside.txt', $outsideCanary.Replace('\', '/'), 'folder/../../outside.txt',
        'file:stream', 'folder/NUL.txt', 'folder/file.')) {
        $zipPath = Join-Path $work 'unsafe.zip'
        $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try { $null = $zip.CreateEntry($entryName) } finally { $zip.Dispose() }
        Write-Checksum $zipPath
        $argsCopy = $defaultArgs.Clone(); $argsCopy.Archive = $zipPath
        Assert-Rejected $argsCopy "unsafe ZIP path $entryName" '^Unsafe or duplicate ZIP entry\.$'
        if (Test-Path -LiteralPath $outsideCanary) { throw 'ZIP validation wrote an outside canary.' }
        Remove-Item -LiteralPath $zipPath, "$zipPath.sha256"
    }
    $zipPath = Join-Path $work 'corrupt.zip'
    [IO.File]::WriteAllText($zipPath, 'not-a-zip')
    Write-Checksum $zipPath
    $argsCopy = $defaultArgs.Clone(); $argsCopy.Archive = $zipPath
    Assert-Rejected $argsCopy 'malformed ZIP' 'Central Directory|corrupt|archive'
    [IO.File]::WriteAllText("$zipPath.sha256", ('0' * 64) + "  corrupt.zip`n")
    Assert-Rejected $argsCopy 'checksum mismatch' '^ZIP checksum mismatch\.$'
    Write-Host 'Installer packaging negative checks passed.'
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::GetFullPath($base)) {
        throw 'Unsafe test cleanup path.'
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
