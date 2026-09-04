$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codexbar-launcher-package-test-$([guid]::NewGuid())"

function New-FakePE {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [uint16] $Machine,

        [Parameter(Mandatory)]
        [byte] $Marker
    )

    $fakePE = [byte[]]::new(512)
    $fakePE[0] = 0x4D
    $fakePE[1] = 0x5A
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($fakePE, 0x3C)
    $fakePE[0x80] = 0x50
    $fakePE[0x81] = 0x45
    [BitConverter]::GetBytes($Machine).CopyTo($fakePE, 0x84)
    [BitConverter]::GetBytes([uint16]0x020B).CopyTo($fakePE, 0x98)
    [BitConverter]::GetBytes([uint16]2).CopyTo($fakePE, 0xDC)
    $fakePE[0x100] = $Marker
    [IO.File]::WriteAllBytes($Path, $fakePE)
}

function New-FakeStaticELF {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [uint16] $Machine
    )

    $fakeELF = [byte[]]::new(64)
    $fakeELF[0] = 0x7F
    $fakeELF[1] = 0x45
    $fakeELF[2] = 0x4C
    $fakeELF[3] = 0x46
    $fakeELF[4] = 2
    $fakeELF[5] = 1
    [BitConverter]::GetBytes($Machine).CopyTo($fakeELF, 18)
    [BitConverter]::GetBytes([uint64]64).CopyTo($fakeELF, 32)
    [BitConverter]::GetBytes([uint16]56).CopyTo($fakeELF, 54)
    [BitConverter]::GetBytes([uint16]0).CopyTo($fakeELF, 56)
    [IO.File]::WriteAllBytes($Path, $fakeELF)
}

try {
    $appDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'app')
    $resourcesDirectory = New-Item -ItemType Directory `
        -Path (Join-Path $appDirectory 'CodexBar_CodexBarWindows.resources')
    [IO.File]::WriteAllBytes((Join-Path $resourcesDirectory 'fixture.bin'), [byte[]](0))
    New-FakePE `
        -Path (Join-Path $appDirectory 'CodexBar.exe') `
        -Machine 0x8664 `
        -Marker 0x11
    $armAppDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'app-arm64')
    Copy-Item `
        -LiteralPath $resourcesDirectory `
        -Destination $armAppDirectory `
        -Recurse
    New-FakePE `
        -Path (Join-Path $armAppDirectory 'CodexBar.exe') `
        -Machine 0xAA64 `
        -Marker 0x12

    $x64RuntimeDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'runtime-x64')
    $arm64RuntimeDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'runtime-arm64')
    $requiredRuntimeDLLs = @(
        'Foundation.dll',
        'FoundationEssentials.dll',
        'msvcp140.dll',
        'swiftCore.dll',
        'swiftCRT.dll',
        'swiftWinSDK.dll',
        'swift_Concurrency.dll',
        'vcruntime140.dll',
        'vcruntime140_1.dll'
    )
    foreach ($runtimeDLL in $requiredRuntimeDLLs) {
        New-FakePE `
            -Path (Join-Path $x64RuntimeDirectory $runtimeDLL) `
            -Machine 0x8664 `
            -Marker 0x64
        New-FakePE `
            -Path (Join-Path $arm64RuntimeDirectory $runtimeDLL) `
            -Machine 0xAA64 `
            -Marker 0xA4
    }

    $payloadDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'payload')
    New-Item -ItemType Directory `
        -Path (Join-Path $payloadDirectory 'CodexBar_CodexBarCore.bundle') | Out-Null
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'VERSION'), '1.0')

    $wslTestRoot = (wsl.exe --exec wslpath -a ($testRoot.Replace('\', '/'))).Trim()
    $wslRepositoryRoot = (wsl.exe --exec wslpath -a ($repositoryRoot.Replace('\', '/'))).Trim()
    $fixtureSource = "$wslRepositoryRoot/TestsLinux/StagingLauncher/fixture_cli.c"
    $launcherSource = "$wslRepositoryRoot/Sources/CodexBarLinuxStagingLauncher/main.c"
    wsl.exe --exec /usr/bin/env -i `
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin `
        /usr/bin/cc -static $fixtureSource -o "$wslTestRoot/payload/CodexBarCLI"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compile the package CLI fixture.'
    }

    $launcher = Join-Path $testRoot 'CodexBarStagingLauncher-linux-musl-x86_64'
    wsl.exe --exec /usr/bin/env -i `
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin `
        /usr/bin/cc -static $launcherSource -o "$wslTestRoot/CodexBarStagingLauncher-linux-musl-x86_64"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compile the package launcher fixture.'
    }

    $archive = Join-Path $testRoot 'CodexBarCLI-v1.0-linux-musl-x86_64.tar.gz'
    tar -czf $archive -C $payloadDirectory CodexBarCLI CodexBar_CodexBarCore.bundle VERSION
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the package CLI fixture archive.'
    }

    $armPayloadDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'payload-arm64')
    New-Item -ItemType Directory `
        -Path (Join-Path $armPayloadDirectory 'CodexBar_CodexBarCore.bundle') | Out-Null
    [IO.File]::WriteAllText((Join-Path $armPayloadDirectory 'VERSION'), '1.0')
    New-FakeStaticELF -Path (Join-Path $armPayloadDirectory 'CodexBarCLI') -Machine 183
    $armLauncher = Join-Path $testRoot 'CodexBarStagingLauncher-linux-musl-aarch64'
    New-FakeStaticELF -Path $armLauncher -Machine 183
    $armArchive = Join-Path $testRoot 'CodexBarCLI-v1.0-linux-musl-aarch64.tar.gz'
    tar -czf $armArchive -C $armPayloadDirectory CodexBarCLI CodexBar_CodexBarCore.bundle VERSION
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the ARM64 package CLI fixture archive.'
    }

    foreach ($file in @($archive, $launcher, $armArchive, $armLauncher)) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($file))" | Set-Content -LiteralPath "$file.sha256" -Encoding ascii
    }

    $packageCases = @(
        [PSCustomObject]@{
            Name = 'x64-matching-first'
            AppDirectory = $appDirectory.FullName
            Archive = $archive
            Launcher = $launcher
            Architecture = 'x86_64'
            Directories = [string[]]@($x64RuntimeDirectory.FullName, $arm64RuntimeDirectory.FullName)
            ExpectedRuntimeDirectory = $x64RuntimeDirectory.FullName
        },
        [PSCustomObject]@{
            Name = 'x64-matching-last'
            AppDirectory = $appDirectory.FullName
            Archive = $archive
            Launcher = $launcher
            Architecture = 'x86_64'
            Directories = [string[]]@($arm64RuntimeDirectory.FullName, $x64RuntimeDirectory.FullName)
            ExpectedRuntimeDirectory = $x64RuntimeDirectory.FullName
        },
        [PSCustomObject]@{
            Name = 'arm64-matching-first'
            AppDirectory = $armAppDirectory.FullName
            Archive = $armArchive
            Launcher = $armLauncher
            Architecture = 'arm64'
            Directories = [string[]]@($arm64RuntimeDirectory.FullName, $x64RuntimeDirectory.FullName)
            ExpectedRuntimeDirectory = $arm64RuntimeDirectory.FullName
        },
        [PSCustomObject]@{
            Name = 'arm64-matching-last'
            AppDirectory = $armAppDirectory.FullName
            Archive = $armArchive
            Launcher = $armLauncher
            Architecture = 'arm64'
            Directories = [string[]]@($x64RuntimeDirectory.FullName, $arm64RuntimeDirectory.FullName)
            ExpectedRuntimeDirectory = $arm64RuntimeDirectory.FullName
        }
    )
    $package = $null
    $expanded = $null
    foreach ($packageCase in $packageCases) {
        $orderedRuntimeDirectories = [string[]]$packageCase.Directories
        $package = & (Join-Path $repositoryRoot 'Scripts/package_windows_release.ps1') `
            -AppBinDirectory $packageCase.AppDirectory `
            -CLIArchive $packageCase.Archive `
            -StagingLauncher $packageCase.Launcher `
            -SafeRefName v1.0 `
            -AssetArchitecture $packageCase.Architecture `
            -RuntimeDirectory $orderedRuntimeDirectories `
            -OutputDirectory (Join-Path $testRoot "out-$($packageCase.Name)")
        $expanded = Join-Path $testRoot "expanded-$($packageCase.Name)"
        Expand-Archive -LiteralPath $package.AssetPath -DestinationPath $expanded

        $expectedRuntimeHash = (
            Get-FileHash `
                -LiteralPath (Join-Path $packageCase.ExpectedRuntimeDirectory 'swiftCore.dll') `
                -Algorithm SHA256
        ).Hash
        $packagedRuntimeHash = (
            Get-FileHash -LiteralPath (Join-Path $expanded 'swiftCore.dll') -Algorithm SHA256
        ).Hash
        if ($packagedRuntimeHash -ine $expectedRuntimeHash) {
            throw "Runtime DLL architecture selection depended on directory order: $($packageCase.Name)"
        }
    }

    $packagedLauncher = Join-Path $expanded 'wsl-cli/CodexBarStagingLauncher'
    $packagedChecksum = (
        Get-Content -LiteralPath (Join-Path $expanded 'wsl-cli/CodexBarStagingLauncher.sha256') -Raw
    ).Trim()
    if ($packagedChecksum -notmatch '^(?<hash>[0-9a-f]{64})  CodexBarStagingLauncher$') {
        throw 'Packaged launcher checksum contract was not preserved.'
    }
    if ((Get-FileHash -LiteralPath $packagedLauncher -Algorithm SHA256).Hash -ine $Matches.hash) {
        throw 'Packaged launcher checksum does not match the packaged launcher.'
    }
    $packagedCLI = Join-Path $expanded 'wsl-cli/CodexBarCLI'
    $packagedCLIChecksum = (
        Get-Content -LiteralPath (Join-Path $expanded 'wsl-cli/CodexBarCLI.sha256') -Raw
    ).Trim()
    if ($packagedCLIChecksum -notmatch '^(?<hash>[0-9a-f]{64})  CodexBarCLI$') {
        throw 'Packaged CLI checksum contract was not preserved.'
    }
    if ((Get-FileHash -LiteralPath $packagedCLI -Algorithm SHA256).Hash -ine $Matches.hash) {
        throw 'Packaged CLI checksum does not match the packaged CLI.'
    }

    Write-Output 'Windows dual-architecture runtime selection and launcher/CLI validation passed'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
