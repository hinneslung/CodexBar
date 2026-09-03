[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppBinDirectory,

    [Parameter(Mandatory)]
    [string] $CLIArchive,

    [Parameter(Mandatory)]
    [string] $StagingLauncher,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]*$')]
    [string] $SafeRefName,

    [Parameter(Mandatory)]
    [ValidateSet('x86_64', 'arm64')]
    [string] $AssetArchitecture,

    [string] $RuntimeDirectory,

    [Parameter(Mandatory)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PackagedPE {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string] $Architecture,

        [switch] $RequireWindowsGUISubsystem
    )

    $bytes = [IO.File]::ReadAllBytes($Executable)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Packaged executable is not a valid PE image: $Executable"
    }

    $peOffset = [BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOffset + 94 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or
        $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or
        $bytes[$peOffset + 3] -ne 0) {
        throw "Packaged executable has an invalid PE header: $Executable"
    }

    $expectedMachine = if ($Architecture -eq 'x86_64') { 0x8664 } else { 0xAA64 }
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne $expectedMachine) {
        throw ('Packaged executable PE Machine is 0x{0:X4}; expected 0x{1:X4} for {2}.' -f
            $machine, $expectedMachine, $Architecture)
    }

    $optionalHeaderOffset = $peOffset + 24
    $optionalHeaderMagic = [BitConverter]::ToUInt16($bytes, $optionalHeaderOffset)
    if ($optionalHeaderMagic -ne 0x020B) {
        throw ('Packaged executable optional-header magic is 0x{0:X4}; expected PE32+ 0x020B.' -f
            $optionalHeaderMagic)
    }

    if ($RequireWindowsGUISubsystem) {
        $subsystem = [BitConverter]::ToUInt16($bytes, $optionalHeaderOffset + 68)
        if ($subsystem -ne 2) {
            throw "Packaged executable subsystem is $subsystem; expected IMAGE_SUBSYSTEM_WINDOWS_GUI (2)."
        }
    }
}

function Assert-StaticLinuxELF {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string] $Architecture
    )

    $bytes = [IO.File]::ReadAllBytes($Executable)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or
        $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
        throw "Staging launcher is not an ELF image: $Executable"
    }
    if ($bytes[4] -ne 2 -or $bytes[5] -ne 1) {
        throw "Staging launcher must be a little-endian ELF64 image: $Executable"
    }
    $expectedMachine = if ($Architecture -eq 'x86_64') { 62 } else { 183 }
    $machine = [BitConverter]::ToUInt16($bytes, 18)
    if ($machine -ne $expectedMachine) {
        throw "Staging launcher ELF machine is $machine; expected $expectedMachine for $Architecture."
    }

    $programHeaderOffset = [BitConverter]::ToUInt64($bytes, 32)
    $programHeaderSize = [BitConverter]::ToUInt16($bytes, 54)
    $programHeaderCount = [BitConverter]::ToUInt16($bytes, 56)
    if ($programHeaderSize -lt 56 -or
        $programHeaderOffset + ($programHeaderSize * $programHeaderCount) -gt $bytes.Length) {
        throw "Staging launcher has an invalid ELF program-header table: $Executable"
    }
    for ($index = 0; $index -lt $programHeaderCount; $index++) {
        $headerOffset = $programHeaderOffset + ($index * $programHeaderSize)
        if ([BitConverter]::ToUInt32($bytes, $headerOffset) -eq 3) {
            throw "Staging launcher is dynamically linked (PT_INTERP present): $Executable"
        }
    }
}

$appBinDirectoryPath = (Resolve-Path -LiteralPath $AppBinDirectory).Path
$cliArchivePath = (Resolve-Path -LiteralPath $CLIArchive).Path
$stagingLauncherPath = (Resolve-Path -LiteralPath $StagingLauncher).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputDirectoryPath = (Resolve-Path -LiteralPath $OutputDirectory).Path

$appExecutable = Join-Path $appBinDirectoryPath 'CodexBar.exe'
$appResources = Join-Path $appBinDirectoryPath 'CodexBar_CodexBarWindows.resources'
if (-not (Test-Path -LiteralPath $appExecutable -PathType Leaf)) {
    throw "Missing Windows executable: $appExecutable"
}
if (-not (Test-Path -LiteralPath $appResources -PathType Container)) {
    throw "Missing Windows resource directory: $appResources"
}

$expectedCLIArchitecture = if ($AssetArchitecture -eq 'x86_64') { 'x86_64' } else { 'aarch64' }
$expectedCLISuffix = "-linux-musl-$expectedCLIArchitecture.tar.gz"
if (-not [IO.Path]::GetFileName($cliArchivePath).EndsWith($expectedCLISuffix, [StringComparison]::Ordinal)) {
    throw "Expected a $expectedCLIArchitecture Linux musl CLI archive; got $cliArchivePath"
}

$cliChecksumPath = "$cliArchivePath.sha256"
if (-not (Test-Path -LiteralPath $cliChecksumPath -PathType Leaf)) {
    throw "Missing Linux CLI checksum: $cliChecksumPath"
}
$cliChecksumLine = (Get-Content -LiteralPath $cliChecksumPath -Raw).Trim()
if ($cliChecksumLine -notmatch '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>\S+)$') {
    throw "Invalid Linux CLI checksum file: $cliChecksumPath"
}
if ($Matches.name -cne [IO.Path]::GetFileName($cliArchivePath)) {
    throw "Linux CLI checksum references an unexpected archive: $($Matches.name)"
}
$actualCLIHash = (Get-FileHash -LiteralPath $cliArchivePath -Algorithm SHA256).Hash
if ($actualCLIHash -ine $Matches.hash) {
    throw "Linux CLI archive checksum mismatch: $cliArchivePath"
}

$expectedLauncherName = "CodexBarStagingLauncher-linux-musl-$expectedCLIArchitecture"
if ([IO.Path]::GetFileName($stagingLauncherPath) -cne $expectedLauncherName) {
    throw "Expected staging launcher $expectedLauncherName; got $stagingLauncherPath"
}
$launcherChecksumPath = "$stagingLauncherPath.sha256"
if (-not (Test-Path -LiteralPath $launcherChecksumPath -PathType Leaf)) {
    throw "Missing staging launcher checksum: $launcherChecksumPath"
}
$launcherChecksumLine = (Get-Content -LiteralPath $launcherChecksumPath -Raw).Trim()
if ($launcherChecksumLine -notmatch '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>\S+)$' -or
    $Matches.name -cne $expectedLauncherName) {
    throw "Invalid staging launcher checksum file: $launcherChecksumPath"
}
$actualLauncherHash = (Get-FileHash -LiteralPath $stagingLauncherPath -Algorithm SHA256).Hash
if ($actualLauncherHash -ine $Matches.hash) {
    throw "Staging launcher checksum mismatch: $stagingLauncherPath"
}
Assert-StaticLinuxELF -Executable $stagingLauncherPath -Architecture $AssetArchitecture

$workRoot = Join-Path ([IO.Path]::GetTempPath()) "codexbar-windows-package-$([guid]::NewGuid())"
$cliExtractDirectory = Join-Path $workRoot 'cli'
$stageDirectory = Join-Path $workRoot 'stage'
$verifyDirectory = Join-Path $workRoot 'verify'
$wslCLIDirectory = Join-Path $stageDirectory 'wsl-cli'
$assetPath = $null
$checksumPath = $null
$completed = $false

try {
    New-Item -ItemType Directory -Path $cliExtractDirectory, $wslCLIDirectory | Out-Null
    tar -xzf $cliArchivePath -C $cliExtractDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not extract the Linux musl CLI payload.'
    }

    Copy-Item -LiteralPath $appExecutable -Destination $stageDirectory
    Copy-Item -LiteralPath $appResources -Destination $stageDirectory -Recurse

    $runtimeDirectories = @(
        if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
            $targetInfo = swiftc -print-target-info | ConvertFrom-Json
            @($targetInfo.paths.runtimeLibraryPaths) |
                Where-Object { Test-Path -LiteralPath $_ -PathType Container }
        } else {
            (Resolve-Path -LiteralPath $RuntimeDirectory).Path
        }
    )
    if ($runtimeDirectories.Count -eq 0) {
        throw 'Swift reported no usable Windows runtime library directory.'
    }
    foreach ($runtimeDirectory in $runtimeDirectories) {
        Get-ChildItem -LiteralPath $runtimeDirectory -Filter '*.dll' -File |
            Copy-Item -Destination $stageDirectory
    }

    $cliPayloadItems = @('CodexBar_CodexBarCore.bundle', 'CodexBarCLI', 'VERSION')
    foreach ($payloadName in $cliPayloadItems) {
        $payloadSource = Join-Path $cliExtractDirectory $payloadName
        if (-not (Test-Path -LiteralPath $payloadSource)) {
            throw "Missing WSL CLI payload item: $payloadName"
        }
        Copy-Item -LiteralPath $payloadSource -Destination $wslCLIDirectory -Recurse
    }
    Assert-StaticLinuxELF `
        -Executable (Join-Path $wslCLIDirectory 'CodexBarCLI') `
        -Architecture $AssetArchitecture
    $packagedCLIHash = (
        Get-FileHash -LiteralPath (Join-Path $wslCLIDirectory 'CodexBarCLI') -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    "$packagedCLIHash  CodexBarCLI" | Set-Content `
        -LiteralPath (Join-Path $wslCLIDirectory 'CodexBarCLI.sha256') `
        -Encoding ascii
    Copy-Item -LiteralPath $stagingLauncherPath `
        -Destination (Join-Path $wslCLIDirectory 'CodexBarStagingLauncher')
    $packagedLauncherHash = $actualLauncherHash.ToLowerInvariant()
    "$packagedLauncherHash  CodexBarStagingLauncher" | Set-Content `
        -LiteralPath (Join-Path $wslCLIDirectory 'CodexBarStagingLauncher.sha256') `
        -Encoding ascii

    $expectedPayloadItems = @(
        'CodexBar_CodexBarCore.bundle',
        'CodexBarCLI',
        'CodexBarCLI.sha256',
        'CodexBarStagingLauncher',
        'CodexBarStagingLauncher.sha256',
        'VERSION'
    )

    $actualPayloadItems = @(Get-ChildItem -LiteralPath $wslCLIDirectory | Sort-Object Name -Unique |
        ForEach-Object Name)
    if (Compare-Object $expectedPayloadItems $actualPayloadItems) {
        throw "Unexpected wsl-cli layout: $($actualPayloadItems -join ', ')"
    }

    $version = if ($SafeRefName.StartsWith('v', [StringComparison]::Ordinal)) {
        $SafeRefName.Substring(1)
    } else {
        $SafeRefName
    }
    if ((Get-Content -LiteralPath (Join-Path $wslCLIDirectory 'VERSION') -Raw).Trim() -ne $version) {
        throw 'The embedded WSL CLI VERSION does not match the Windows archive version.'
    }
    Copy-Item -LiteralPath (Join-Path $wslCLIDirectory 'VERSION') -Destination $stageDirectory

    Assert-PackagedPE `
        -Executable (Join-Path $stageDirectory 'CodexBar.exe') `
        -Architecture $AssetArchitecture `
        -RequireWindowsGUISubsystem

    $assetName = "CodexBar-$SafeRefName-windows-$AssetArchitecture.zip"
    $assetPath = Join-Path $outputDirectoryPath $assetName
    $checksumPath = "$assetPath.sha256"
    if (Test-Path -LiteralPath $assetPath) {
        throw "Refusing to overwrite existing Windows release asset: $assetPath"
    }
    if (Test-Path -LiteralPath $checksumPath) {
        throw "Refusing to overwrite existing Windows release checksum: $checksumPath"
    }

    Compress-Archive -Path (Join-Path $stageDirectory '*') -DestinationPath $assetPath
    Expand-Archive -LiteralPath $assetPath -DestinationPath $verifyDirectory

    $requiredPackagePaths = @(
        'CodexBar.exe',
        'CodexBar_CodexBarWindows.resources',
        'Foundation.dll',
        'FoundationEssentials.dll',
        'msvcp140.dll',
        'swiftCore.dll',
        'swiftCRT.dll',
        'swiftWinSDK.dll',
        'swift_Concurrency.dll',
        'vcruntime140.dll',
        'VERSION',
        'wsl-cli/CodexBarCLI',
        'wsl-cli/CodexBarCLI.sha256',
        'wsl-cli/CodexBarStagingLauncher',
        'wsl-cli/CodexBarStagingLauncher.sha256',
        'wsl-cli/VERSION',
        'wsl-cli/CodexBar_CodexBarCore.bundle'
    )
    if ($AssetArchitecture -eq 'x86_64') {
        # The x64 MSVC runtime uses this separate exception-handling helper; ARM64 does not.
        $requiredPackagePaths += 'vcruntime140_1.dll'
    }
    foreach ($relativePath in $requiredPackagePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $verifyDirectory $relativePath))) {
            throw "Packaged archive is missing: $relativePath"
        }
    }
    $verifiedPayloadItems = @(Get-ChildItem -LiteralPath (Join-Path $verifyDirectory 'wsl-cli') |
        Sort-Object Name -Unique | ForEach-Object Name)
    if (Compare-Object $expectedPayloadItems $verifiedPayloadItems) {
        throw "Packaged archive has an unexpected wsl-cli layout: $($verifiedPayloadItems -join ', ')"
    }
    Assert-StaticLinuxELF `
        -Executable (Join-Path $verifyDirectory 'wsl-cli/CodexBarCLI') `
        -Architecture $AssetArchitecture
    $verifiedCLIChecksum = (
        Get-Content -LiteralPath (Join-Path $verifyDirectory 'wsl-cli/CodexBarCLI.sha256') -Raw
    ).Trim()
    if ($verifiedCLIChecksum -notmatch '^(?<hash>[0-9a-f]{64})  CodexBarCLI$') {
        throw 'Packaged WSL CLI checksum has an invalid format.'
    }
    $verifiedCLIHash = (
        Get-FileHash -LiteralPath (Join-Path $verifyDirectory 'wsl-cli/CodexBarCLI') -Algorithm SHA256
    ).Hash
    if ($verifiedCLIHash -ine $Matches.hash) {
        throw 'Packaged WSL CLI checksum mismatch.'
    }
    Assert-StaticLinuxELF `
        -Executable (Join-Path $verifyDirectory 'wsl-cli/CodexBarStagingLauncher') `
        -Architecture $AssetArchitecture
    $verifiedLauncherChecksum = (
        Get-Content -LiteralPath (Join-Path $verifyDirectory 'wsl-cli/CodexBarStagingLauncher.sha256') -Raw
    ).Trim()
    if ($verifiedLauncherChecksum -notmatch '^(?<hash>[0-9a-f]{64})  CodexBarStagingLauncher$') {
        throw 'Packaged staging launcher checksum has an invalid format.'
    }
    $verifiedLauncherHash = (
        Get-FileHash -LiteralPath (Join-Path $verifyDirectory 'wsl-cli/CodexBarStagingLauncher') -Algorithm SHA256
    ).Hash
    if ($verifiedLauncherHash -ine $Matches.hash) {
        throw 'Packaged staging launcher checksum mismatch.'
    }
    Assert-PackagedPE `
        -Executable (Join-Path $verifyDirectory 'CodexBar.exe') `
        -Architecture $AssetArchitecture `
        -RequireWindowsGUISubsystem
    Get-ChildItem -LiteralPath $verifyDirectory -Filter '*.dll' -File | ForEach-Object {
        Assert-PackagedPE -Executable $_.FullName -Architecture $AssetArchitecture
    }

    $hash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $assetName" | Set-Content -LiteralPath $checksumPath -Encoding ascii

    $completed = $true
    [PSCustomObject]@{
        AssetPath = $assetPath
        ChecksumPath = $checksumPath
    }
} finally {
    if (-not $completed) {
        foreach ($partialOutput in @($assetPath, $checksumPath)) {
            if ($null -ne $partialOutput -and (Test-Path -LiteralPath $partialOutput -PathType Leaf)) {
                Remove-Item -LiteralPath $partialOutput -Force
            }
        }
    }
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
