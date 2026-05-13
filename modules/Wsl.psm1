# Wsl.psm1
# Foundation layer for everything that touches the distro. Every module that
# runs bash inside the distro goes through one of the two `Invoke-` primitives
# below — they handle both the systemd-warning filtering and the pwsh-to-bash
# argv-mangling workaround documented in docs/wsl2-gotchas.md.
#
# Public surface:
#   Distro lifecycle
#     Get-WslDistros                — parse `wsl --list --verbose` (UTF-8 via WSL_UTF8)
#     ConvertFrom-WslListVerbose    — pure parser; takes raw text, used by Get-WslDistros + tests
#     Test-DistroExists -Name
#     Get-DistroState   -Name
#     Import-Distro     -Name -RootfsPath -InstallPath
#     Unregister-Distro -Name
#     Stop-Distro       -Name
#   Bash-in-distro execution
#     Invoke-InDistro       -Name -Command [-User] [-WorkingDir] [-AllowFail] [-CaptureOutput]
#                           — single-line / argv-safe commands
#     Invoke-InDistroScript -Name -Script  [-User]                [-AllowFail] [-CaptureOutput]
#                           — multi-line / $VAR-using scripts, transported via base64
#     ConvertTo-BashQuoted -Value <s>      — POSIX single-quote escape for splices
#   Rootfs acquisition
#     Resolve-LatestDebianRootfsUrl       — scrape images.linuxcontainers.org
#     Save-Rootfs            -Url -DestPath
#     Convert-RootfsToTar    -SourcePath -DestPath  — .tar / .tar.gz / .tar.xz -> plain .tar
#     Expand-Gzip / Expand-Xz             — primitive decompressors used by Convert
#
# Side effect on module load: sets $env:WSL_UTF8 = '1' so `wsl --list` returns
# UTF-8 (not UTF-16LE, the default on Windows). All later parsing assumes UTF-8.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WSL outputs UTF-16LE by default; this knob switches it to UTF-8 (WSL 0.65+).
$env:WSL_UTF8 = '1'

function ConvertFrom-WslListVerbose {
    # Pure parser for the output of `wsl.exe --list --verbose`. Pulled out of
    # Get-WslDistros so the parsing — which has to survive UTF-8 / CRLF / a
    # leading `*` on the default distro / NAME-STATE header — can be tested
    # against captured fixture text.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Raw)
    # `,$result` preserves array shape across the function boundary — without
    # the unary comma, pwsh unwraps a 0- or 1-element array, and callers that
    # do `.Count` under StrictMode would throw on the empty case. The two
    # exits assign to $result first so the comma binds to a variable
    # reference, matching the pattern used elsewhere in the repo.
    $result = @()
    if (-not $Raw) { return ,$result }
    $lines = $Raw -split "`r?`n" |
        Where-Object { $_ -and ($_ -notmatch '^\s*NAME\s+STATE') -and $_.Trim() }
    foreach ($line in $lines) {
        $clean = ($line -replace '^\s*\*?\s*', '').Trim()
        if (-not $clean) { continue }
        $parts = $clean -split '\s{2,}'
        if ($parts.Length -ge 2) {
            $result += [PSCustomObject]@{
                Name    = $parts[0].Trim()
                State   = $parts[1].Trim()
                Version = if ($parts.Length -ge 3) { $parts[2].Trim() } else { '' }
            }
        }
    }
    return ,$result
}

function Get-WslDistros {
    [CmdletBinding()] param()
    $raw = & wsl.exe --list --verbose 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    # Capture-then-emit unwraps the parser's `,$result` shape wrap before the
    # pipeline sees it. `return ConvertFrom...` directly would pass the wrap
    # through and feed Where-Object a single Object[] value, breaking
    # `$_.Name` access under StrictMode (this regressed CI when the runner
    # had any distros to enumerate). All current Get-WslDistros consumers
    # are pipelines — Test-DistroExists / Get-DistroState — so emitting
    # nothing on empty (the `return @()` branch above) is correct for them.
    $distros = ConvertFrom-WslListVerbose -Raw ($raw -join "`n")
    return $distros
}

function Test-DistroExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-WslDistros | Where-Object { $_.Name -eq $Name })
}

function Get-DistroState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $d = Get-WslDistros | Where-Object { $_.Name -eq $Name }
    if (-not $d) { return 'Missing' }
    return $d.State
}

function Import-Distro {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RootfsPath,
        [Parameter(Mandatory)][string]$InstallPath
    )
    # -LiteralPath so wildcard glyphs ([, ], *) in the rootfs path aren't
    # interpreted by the provider (same hazard class as wsl2-gotchas #19).
    if (-not (Test-Path -LiteralPath $RootfsPath -PathType Leaf)) { throw "Rootfs not found: $RootfsPath" }
    # .NET API (literal + idempotent); wsl2-gotchas #19.
    [void][System.IO.Directory]::CreateDirectory($InstallPath)
    & wsl.exe --import $Name $InstallPath $RootfsPath --version 2
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed (exit $LASTEXITCODE)" }
}

function Unregister-Distro {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    & wsl.exe --unregister $Name
    if ($LASTEXITCODE -ne 0) { throw "wsl --unregister failed (exit $LASTEXITCODE)" }
}

function Stop-Distro {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    & wsl.exe -t $Name | Out-Null
    # exit code may be non-zero if distro was already stopped — that's fine.
}

function ConvertTo-BashQuoted {
    # Wrap a string in POSIX single quotes, escaping embedded single quotes.
    # Use this for any value you splice into a bash command line.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'$(($Value -replace "'", "'\''"))'"
}

function Invoke-InDistro {
    # Run a bash command inside the distro. Throws on non-zero exit unless -AllowFail.
    # When -CaptureOutput is set, returns @{ ExitCode; Output (string[]) } instead of
    # streaming to the host console.
    #
    # IMPORTANT: pwsh -> wsl.exe -> bash argv passing mangles unescaped '$' (a literal
    # `$LITERAL` in the script becomes empty before bash sees it). For multi-line
    # scripts or anything using bash variables, use Invoke-InDistroScript which
    # base64-transports the script body intact.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$User = 'root',
        [string]$WorkingDir,
        [switch]$AllowFail,
        [switch]$CaptureOutput
    )
    $cliArgs = @('-d', $Name, '-u', $User)
    if ($WorkingDir) { $cliArgs += @('--cd', $WorkingDir) }
    $cliArgs += @('--', 'bash', '-lc', $Command)

    # Filter the harmless 'wsl: Failed to start the systemd user session ...'
    # warning out of the output stream. It appears intermittently for any wsl -u
    # invocation when systemd-logind isn't running (a known WSL2+systemd quirk —
    # the proper fix needs loginctl enable-linger, which itself requires logind
    # to be up, which requires a manual systemctl start dance that hangs in WSL2).
    # See README troubleshooting.
    $isSystemdNoise = {
        param($Line)
        if ($null -eq $Line) { return $false }
        $s = [string]$Line
        return ($s -match 'Failed to start the systemd user session')
    }

    if ($CaptureOutput) {
        $rawOut = & wsl.exe @cliArgs 2>&1
        $code = $LASTEXITCODE
        $out = @($rawOut | Where-Object { -not (& $isSystemdNoise $_) })
        if ($code -ne 0 -and -not $AllowFail) {
            throw "Invoke-InDistro failed (exit $code) for: $Command`n$($out -join "`n")"
        }
        return @{ ExitCode = $code; Output = $out }
    }
    & wsl.exe @cliArgs 2>&1 | Where-Object { -not (& $isSystemdNoise $_) }
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "Invoke-InDistro failed (exit $code) for: $Command"
    }
    # Intentionally no return value — letting $code escape pollutes the pipeline.
}

function Invoke-InDistroScript {
    # Run a multi-line / variable-using bash script intact. The script is base64-
    # encoded on the pwsh side and decoded inside the distro, bypassing the pwsh
    # -> wsl.exe argv-mangling that strips backslashes and pre-expands '$VAR'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [string]$User = 'root',
        [switch]$AllowFail,
        [switch]$CaptureOutput
    )
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    # The wrapper itself uses no '$' references and only ASCII content — safe for argv.
    $wrapper = "printf '%s' '$b64' | base64 -d | bash -l"
    Invoke-InDistro -Name $Name -Command $wrapper -User $User -AllowFail:$AllowFail -CaptureOutput:$CaptureOutput
}

function Resolve-LatestDebianRootfsUrl {
    [CmdletBinding()]
    param(
        [string]$Release = 'bookworm',
        [string]$Variant = 'default',
        [string]$Arch    = 'amd64'
    )
    $base = "https://images.linuxcontainers.org/images/debian/$Release/$Arch/$Variant/"
    $html = Invoke-WebRequest -Uri $base -UseBasicParsing
    # The listing URL-encodes `:` as `%3A` inside href values. Match the encoded form
    # since we'll splice the capture group straight back into the download URL.
    $stamps = [regex]::Matches($html.Content, 'href="(\d{8}_\d{2}%3[Aa]\d{2})/"') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    if (-not $stamps) { throw "Could not resolve latest rootfs timestamp at $base" }
    $latest = ($stamps | Sort-Object -Descending | Select-Object -First 1)
    return "$base$latest/rootfs.tar.xz"
}

function Save-Rootfs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestPath
    )
    $dir = Split-Path -Parent $DestPath
    # .NET API (literal + idempotent); wsl2-gotchas #19.
    [void][System.IO.Directory]::CreateDirectory($dir)
    Write-Host "  Downloading $Url"
    Write-Host "  -> $DestPath"
    Invoke-WebRequest -Uri $Url -OutFile $DestPath -UseBasicParsing
}

function Convert-RootfsToTar {
    # wsl --import wants an uncompressed .tar. For compressed sources we just need to
    # decompress (single step) — no extract+re-pack needed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )
    $src = (Resolve-Path $SourcePath).Path
    $name = [IO.Path]::GetFileName($src).ToLowerInvariant()

    if ($name.EndsWith('.tar')) {
        if ($src -ne $DestPath) { Copy-Item -LiteralPath $src -Destination $DestPath -Force }
        return
    }
    if ($name.EndsWith('.tar.gz') -or $name.EndsWith('.tgz')) {
        Expand-Gzip -SourcePath $src -DestPath $DestPath
        return
    }
    if ($name.EndsWith('.tar.xz') -or $name.EndsWith('.txz')) {
        Expand-Xz -SourcePath $src -DestPath $DestPath
        return
    }
    throw "Unsupported rootfs extension: $name (expected .tar / .tar.gz / .tar.xz)"
}

function Expand-Gzip {
    # Native .NET — always available, no external tool needed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )
    Write-Host "  Decompressing via .NET GZipStream..."
    $in = [IO.File]::OpenRead($SourcePath)
    try {
        $gz = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
        try {
            $out = [IO.File]::Create($DestPath)
            try   { $gz.CopyTo($out) }
            finally { $out.Dispose() }
        }
        finally { $gz.Dispose() }
    }
    finally { $in.Dispose() }
}

function Expand-Xz {
    # No native .NET xz support. Try external tools in priority order.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )

    # 1. 7-Zip — common on dev machines. Check PATH + well-known install dirs.
    $sevenZip = $null
    $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($c) { $sevenZip = $c.Source }
    if (-not $sevenZip) {
        foreach ($p in @(
            'C:\Program Files\7-Zip\7z.exe',
            'C:\Program Files (x86)\7-Zip\7z.exe',
            'C:\ProgramData\chocolatey\bin\7z.exe'
        )) {
            if (Test-Path -LiteralPath $p -PathType Leaf) { $sevenZip = $p; break }
        }
    }
    if ($sevenZip) {
        Write-Host "  Decompressing via 7-Zip: $sevenZip"
        $outDir = Split-Path -Parent $DestPath
        # .NET API (literal + idempotent); wsl2-gotchas #19.
        [void][System.IO.Directory]::CreateDirectory($outDir)
        & $sevenZip e -y "-bso0" "-bsp0" "-o$outDir" $SourcePath
        if ($LASTEXITCODE -ne 0) { throw "7z extraction failed (exit $LASTEXITCODE)" }
        # 7z strips only the .xz/.gz extension, leaving the inner name (e.g. rootfs.tar.xz -> rootfs.tar).
        $produced = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($SourcePath))
        if (-not (Test-Path -LiteralPath $produced -PathType Leaf)) { throw "7z produced no output at $produced" }
        if ($produced -ne $DestPath) { Move-Item -LiteralPath $produced -Destination $DestPath -Force }
        return
    }

    # 2. xz / unxz on PATH (MSYS2, scoop, chocolatey).
    $xz = (Get-Command xz.exe   -ErrorAction SilentlyContinue)
    if (-not $xz) { $xz = (Get-Command unxz.exe -ErrorAction SilentlyContinue) }
    if ($xz) {
        Write-Host "  Decompressing via $($xz.Source)..."
        # xz -d decompresses in place and renames .xz -> bare name. Stage a copy to
        # preserve the source.
        $stage = "$DestPath.xz"
        Copy-Item -LiteralPath $SourcePath -Destination $stage -Force
        & $xz.Source -d $stage
        if ($LASTEXITCODE -ne 0) { throw "xz -d failed (exit $LASTEXITCODE)" }
        if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) { throw "xz produced no output at $DestPath" }
        return
    }

    # 3. Python lzma module — included with any stock Python 3 install.
    $py = $null
    foreach ($n in @('python.exe','python','python3.exe','python3')) {
        $c2 = Get-Command $n -ErrorAction SilentlyContinue
        if ($c2) { $py = $c2.Source; break }
    }
    if ($py) {
        Write-Host "  Decompressing via Python lzma module: $py"
        $pyScript = @'
import lzma, sys, shutil
with lzma.open(sys.argv[1], 'rb') as f_in, open(sys.argv[2], 'wb') as f_out:
    shutil.copyfileobj(f_in, f_out, length=1024*1024)
'@
        & $py -c $pyScript $SourcePath $DestPath
        if ($LASTEXITCODE -ne 0) { throw "python lzma decompression failed (exit $LASTEXITCODE)" }
        return
    }

    throw @"
Could not decompress .tar.xz: no xz-capable tool found on this machine.
Tried: 7z (PATH and common install paths), xz, unxz, python (lzma module).

Quick fixes:
  - Install 7-Zip:   winget install 7zip.7zip
  - Or pre-decompress and pass:   -RootfsPath <path>\rootfs.tar
"@
}

Export-ModuleMember -Function `
    Get-WslDistros, `
    ConvertFrom-WslListVerbose, `
    Test-DistroExists, `
    Get-DistroState, `
    Import-Distro, `
    Unregister-Distro, `
    Stop-Distro, `
    ConvertTo-BashQuoted, `
    Invoke-InDistro, `
    Invoke-InDistroScript, `
    Resolve-LatestDebianRootfsUrl, `
    Save-Rootfs, `
    Convert-RootfsToTar, `
    Expand-Gzip, `
    Expand-Xz
