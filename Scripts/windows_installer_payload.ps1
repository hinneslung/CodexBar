# Shared validation for installer packaging and lifecycle verification. No payload is executed here.
Set-StrictMode -Version Latest

function Expand-VerifiedWindowsPayload {
    param([string] $Archive, [string] $Architecture, [string] $Destination)
    $archivePath = (Resolve-Path -LiteralPath $Archive).Path
    $line = (Get-Content -LiteralPath "$archivePath.sha256" -Raw).Trim()
    if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<name>[^\r\n]+)$' -or
        $Matches.name -cne [IO.Path]::GetFileName($archivePath)) { throw 'Invalid ZIP checksum sidecar.' }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $Matches.hash) {
        throw 'ZIP checksum mismatch.'
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long] $total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $parts = $name.TrimEnd('/').Split('/')
            if ($name.StartsWith('/') -or $parts.Count -eq 0 -or
                ($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or
                    $_ -match '[<>:"|?*\x00-\x1f]' -or $_ -match '[. ]$' -or
                    $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }) -or
                -not $seen.Add($name.TrimEnd('/')) -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Unsafe or duplicate ZIP entry.'
            }
            $total += $entry.Length
            if ($total -gt 2GB -or $zip.Entries.Count -gt 20000) { throw 'ZIP payload exceeds limits.' }
        }
        if (Test-Path -LiteralPath $Destination) { throw 'Extraction directory already exists.' }
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        foreach ($entry in $zip.Entries) {
            $target = Join-Path $Destination $entry.FullName.Replace('\', '/')
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
            } else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    } finally { $zip.Dispose() }
    $required = @('CodexBar.exe', 'CodexBar_CodexBarWindows.resources', 'Foundation.dll',
        'FoundationEssentials.dll', 'msvcp140.dll', 'swiftCore.dll', 'swiftCRT.dll', 'swiftWinSDK.dll',
        'swift_Concurrency.dll', 'vcruntime140.dll', 'VERSION', 'wsl-cli/CodexBarCLI',
        'wsl-cli/CodexBarCLI.sha256', 'wsl-cli/CodexBarStagingLauncher',
        'wsl-cli/CodexBarStagingLauncher.sha256', 'wsl-cli/VERSION', 'wsl-cli/CodexBar_CodexBarCore.bundle')
    if ($Architecture -eq 'x86_64') { $required += 'vcruntime140_1.dll' }
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $path))) { throw "Missing payload item: $path" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Destination) {
        if ($item.Name -notin @('CodexBar.exe', 'CodexBar_CodexBarWindows.resources', 'VERSION', 'wsl-cli') -and
            ($item.PSIsContainer -or $item.Extension -ine '.dll')) { throw 'Unexpected payload root item.' }
    }
    $expectedWSL = @('CodexBarCLI', 'CodexBarCLI.sha256', 'CodexBarStagingLauncher',
        'CodexBarStagingLauncher.sha256', 'CodexBar_CodexBarCore.bundle', 'VERSION')
    if (Compare-Object $expectedWSL @(Get-ChildItem (Join-Path $Destination 'wsl-cli') | ForEach-Object Name)) {
        throw 'Unexpected WSL payload layout.'
    }
    $expectedMachine = if ($Architecture -eq 'x86_64') { 0x8664 } else { 0xAA64 }
    foreach ($file in Get-ChildItem $Destination -File | Where-Object { $_.Extension -in '.exe', '.dll' }) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Invalid PE image.' }
        $offset = [BitConverter]::ToUInt32($bytes, 60)
        if ([long]$offset + 94 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or
            [BitConverter]::ToUInt16($bytes, $offset + 4) -ne $expectedMachine -or
            [BitConverter]::ToUInt16($bytes, $offset + 24) -ne 0x20B) { throw 'PE architecture mismatch.' }
        if ($file.Extension -eq '.exe' -and [BitConverter]::ToUInt16($bytes, $offset + 92) -ne 2) {
            throw 'App must use the Windows GUI subsystem.'
        }
    }
    foreach ($name in @('CodexBarCLI', 'CodexBarStagingLauncher')) {
        $path = Join-Path $Destination "wsl-cli/$name"
        $bytes = [IO.File]::ReadAllBytes($path)
        $machine = if ($Architecture -eq 'x86_64') { 62 } else { 183 }
        if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt32($bytes, 0) -ne 0x464C457F -or
            $bytes[4] -ne 2 -or $bytes[5] -ne 1 -or [BitConverter]::ToUInt16($bytes, 18) -ne $machine) {
            throw 'WSL ELF architecture mismatch.'
        }
        $offset = [BitConverter]::ToUInt64($bytes, 32)
        $size = [BitConverter]::ToUInt16($bytes, 54)
        $count = [BitConverter]::ToUInt16($bytes, 56)
        if ($size -lt 56 -or $offset -gt $bytes.Length -or $count * $size -gt $bytes.Length - $offset) {
            throw 'Invalid ELF program headers.'
        }
        for ($i = 0; $i -lt $count; $i++) {
            if ([BitConverter]::ToUInt32($bytes, ($offset + $i * $size)) -eq 3) { throw 'WSL ELF is not static.' }
        }
        $sum = (Get-Content -LiteralPath "$path.sha256" -Raw).Trim()
        if ($sum -cnotmatch ('^(?<hash>[0-9a-f]{64})  ' + $name + '$') -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Matches.hash) {
            throw 'WSL payload checksum mismatch.'
        }
    }
}
