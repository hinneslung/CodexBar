[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DestinationDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pinned official release: https://github.com/jrsoftware/issrc/releases/tag/is-6_7_3
$version = '6.7.3'
$expectedHash = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
$downloadURL = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
if ($destination -eq [IO.Path]::GetPathRoot($destination)) {
    throw 'Choose a dedicated Inno Setup tooling directory.'
}
if (Test-Path -LiteralPath $destination) {
    throw "Inno Setup destination already exists: $destination"
}
$parentDirectory = Split-Path -Parent $destination
New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
$downloadPath = Join-Path $parentDirectory ("innosetup-$version-" + [Guid]::NewGuid().ToString('N') + '.exe')
try {
    Invoke-WebRequest -Uri $downloadURL -OutFile $downloadPath -TimeoutSec 90
    if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ine $expectedHash) {
        throw 'The Inno Setup download does not match the pinned SHA-256.'
    }

    # Official /PORTABLE=1 avoids associations, shortcuts, and uninstall registration.
    $process = Start-Process -FilePath $downloadPath -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER',
        '/PORTABLE=1', ('/DIR="' + $destination + '"')
    ) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(180000)) {
        Stop-Process -Id $process.Id -Force
        throw 'Inno Setup tooling installation timed out.'
    }
    if ($process.ExitCode -ne 0) {
        throw "Inno Setup tooling installation failed with exit code $($process.ExitCode)."
    }
    $compilerPath = Join-Path $destination 'ISCC.exe'
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        throw 'Inno Setup did not install its command-line compiler.'
    }
    # This official build has 0.0.0.0 PE version resources. The installer hash above
    # pins the compiler version; do not infer it from those placeholder resources.
    [PSCustomObject]@{ CompilerPath = $compilerPath; Version = $version }
} finally {
    if (Test-Path -LiteralPath $downloadPath -PathType Leaf) {
        Remove-Item -LiteralPath $downloadPath -Force
    }
}
