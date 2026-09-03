$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codexbar-launcher-package-test-$([guid]::NewGuid())"

try {
    $appDirectory = New-Item -ItemType Directory -Path (Join-Path $testRoot 'app')
    $resourcesDirectory = New-Item -ItemType Directory `
        -Path (Join-Path $appDirectory 'CodexBar_CodexBarWindows.resources')
    [IO.File]::WriteAllBytes((Join-Path $resourcesDirectory 'fixture.bin'), [byte[]](0))
    $fakePE = [byte[]]::new(512)
    $fakePE[0] = 0x4D
    $fakePE[1] = 0x5A
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($fakePE, 0x3C)
    $fakePE[0x80] = 0x50
    $fakePE[0x81] = 0x45
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($fakePE, 0x84)
    [BitConverter]::GetBytes([uint16]0x020B).CopyTo($fakePE, 0x98)
    [BitConverter]::GetBytes([uint16]2).CopyTo($fakePE, 0xDC)
    [IO.File]::WriteAllBytes((Join-Path $appDirectory 'CodexBar.exe'), $fakePE)

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
    foreach ($file in @($archive, $launcher)) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($file))" | Set-Content -LiteralPath "$file.sha256" -Encoding ascii
    }

    $package = & (Join-Path $repositoryRoot 'Scripts/package_windows_release.ps1') `
        -AppBinDirectory $appDirectory `
        -CLIArchive $archive `
        -StagingLauncher $launcher `
        -SafeRefName v1.0 `
        -AssetArchitecture x86_64 `
        -OutputDirectory (Join-Path $testRoot 'out')
    $expanded = Join-Path $testRoot 'expanded'
    Expand-Archive -LiteralPath $package.AssetPath -DestinationPath $expanded
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

    Write-Output 'Windows package launcher/CLI ELF and checksum validation passed'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
