[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Archive,
    [Parameter(Mandatory)][ValidateSet('x86_64', 'arm64')][string] $AssetArchitecture,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]{0,99}$')][string] $SafeRefName,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [string] $CompilerPath,
    [string] $VersionFile = (Join-Path $PSScriptRoot '../version.env'),
    [switch] $ValidateOnly,
    # Local QA builds have a separate application and task identity and cannot be release assets.
    [switch] $TestIdentity
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_installer_payload.ps1')
$versionText = Get-Content -LiteralPath $VersionFile -Raw
if ($versionText -notmatch '(?m)^MARKETING_VERSION=(\d+)\.(\d+)\.(\d+)\r?$') { throw 'Invalid marketing version.' }
$numbers = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
if ($versionText -notmatch '(?m)^BUILD_NUMBER=(\d+)\r?$') { throw 'Invalid build number.' }
$numbers += [int]$Matches[1]
if ($numbers | Where-Object { $_ -lt 0 -or $_ -gt 65535 }) { throw 'Version component exceeds Windows limits.' }
$version = $numbers -join '.'
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$suffix = if ($TestIdentity) { '-qa' } else { '' }
$assetName = "CodexBar-$SafeRefName-windows-$AssetArchitecture$suffix-setup"
$asset = Join-Path $outputRoot "$assetName.exe"
$checksum = "$asset.sha256"
if ((Test-Path -LiteralPath $asset) -or (Test-Path -LiteralPath $checksum)) { throw 'Refusing to overwrite installer output.' }
$tempBase = Join-Path ([IO.Path]::GetTempPath()) 'CodexBar'
[IO.Directory]::CreateDirectory($tempBase) | Out-Null
$work = Join-Path $tempBase ('installer-package-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($work) | Out-Null
$completed = $false
$createdOutput = $false
try {
    $payload = Join-Path $work 'payload'
    Expand-VerifiedWindowsPayload -Archive $Archive -Architecture $AssetArchitecture -Destination $payload
    $expectedVersion = $SafeRefName -creplace '^v', ''
    foreach ($path in @('VERSION', 'wsl-cli/VERSION')) {
        if ((Get-Content -LiteralPath (Join-Path $payload $path) -Raw).Trim() -cne $expectedVersion) {
            throw 'Payload version does not match requested ref.'
        }
    }
    if ($ValidateOnly) { return }
    if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw 'Supply the verified Inno Setup compiler path.'
    }
    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $defines = @("/DPayloadDirectory=$payload", "/DOutputDirectory=$work", "/DAssetName=$assetName",
        "/DAssetArchitecture=$AssetArchitecture", "/DDisplayVersion=$SafeRefName", "/DNumericVersion=$version")
    if ($TestIdentity) { $defines += '/DTestIdentity=1' }
    & $CompilerPath @defines (Join-Path $PSScriptRoot 'windows-installer.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed: $LASTEXITCODE" }
    $compiled = Join-Path $work "$assetName.exe"
    # CreateNew semantics prevent replacing an output created by another invocation.
    [IO.File]::Copy($compiled, $asset, $false)
    $createdOutput = $true
    $hash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
    $stream = [IO.File]::Open($checksum, [IO.FileMode]::CreateNew)
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes("$hash  $assetName.exe`n")
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    $completed = $true
    [pscustomobject]@{ AssetPath = $asset; ChecksumPath = $checksum }
} finally {
    if (-not $completed -and $createdOutput) { Remove-Item -LiteralPath $asset -Force }
    # $work is a fresh UUID child of the explicit task temporary directory.
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne $tempBase) { throw 'Unsafe cleanup path.' }
    Remove-Item -LiteralPath $work -Recurse -Force
}
