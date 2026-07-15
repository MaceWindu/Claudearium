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
#   Directory-tree transport (gzip-tar + base64, mirrors the single-file hop)
#     ConvertTo-TarGzBase64 -SourceDir     — pack a dir's CONTENTS -> base64(gzip(tar))
#     Send-TreeToDistro     -DistroName -SourceDir -DestDir [-Merge]
#     Expand-ArchiveToDistro -DistroName -ArchivePath -DestDir [-Clean]
#     Receive-TreeFromDistro -DistroName -SourceDir -DestArchivePath  — distro dir -> host .tar.gz
#     Expand-TarGzToHostDir  -ArchivePath -DestDir   — extract a host .tar.gz into a host dir
#   Rootfs acquisition
#     Resolve-LatestDebianRootfsUrl       — scrape images.linuxcontainers.org
#     Save-Rootfs            -Url -DestPath
#     Convert-RootfsToTar    -SourcePath -DestPath  — .tar / .tar.gz / .tar.xz -> plain .tar
#     Expand-Gzip / Expand-Xz             — primitive decompressors used by Convert
#     Expand-XzManaged       -SourcePath -DestPath  — pure-managed .xz (LZMA2) decode,
#                                                     no external codec required
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

function ConvertTo-TarGzBase64 {
    # Pack a directory's CONTENTS (not the directory itself) into a gzip'd tar
    # and return it base64-encoded. Used to transport skills/ and agents/ trees
    # into the distro over the same base64 hop the single-file writers use.
    # Prefers .NET 8 System.Formats.Tar; falls back to the bundled bsdtar
    # (tar.exe) on Windows if the type is unavailable.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceDir)
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "ConvertTo-TarGzBase64: source directory not found: $SourceDir"
    }
    $src = (Resolve-Path -LiteralPath $SourceDir).Path
    $bytes = $null
    if ('System.Formats.Tar.TarFile' -as [type]) {
        $ms = [System.IO.MemoryStream]::new()
        try {
            # leaveOpen so disposing the gzip stream (to flush) doesn't close $ms
            # before ToArray. includeBaseDirectory:$false -> entries are relative
            # to $src, so `tar -xz -C <dest>` lands them directly under <dest>.
            $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
            try { [System.Formats.Tar.TarFile]::CreateFromDirectory($src, $gz, $false) }
            finally { $gz.Dispose() }
            $bytes = $ms.ToArray()
        }
        finally { $ms.Dispose() }
    }
    else {
        # bsdtar ships as tar.exe on Windows 10/11. `-C $src .` packs contents.
        $tarExe = Join-Path $env:WINDIR 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
            throw 'ConvertTo-TarGzBase64: System.Formats.Tar unavailable and no tar.exe fallback found.'
        }
        $tmp = [IO.Path]::GetTempFileName()
        try {
            & $tarExe -czf $tmp -C $src .
            if ($LASTEXITCODE -ne 0) { throw "tar.exe pack failed (exit $LASTEXITCODE)" }
            $bytes = [IO.File]::ReadAllBytes($tmp)
        }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return [Convert]::ToBase64String($bytes)
}

function Send-TreeToDistro {
    # Extract a host directory's CONTENTS into a distro directory as root, via
    # gzip-tar + base64. With -Merge, pre-existing files in DestDir survive
    # (union, no clobber); without it the tar is extracted straight in
    # (overwrite-on-conflict). Ownership/permissions are the caller's job — the
    # shared store normalizes group + ACLs afterward.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir,
        [switch]$Merge
    )
    $b64 = ConvertTo-TarGzBase64 -SourceDir $SourceDir
    if ($b64.Length -gt 1MB) {
        Write-Warning ("Send-TreeToDistro: large payload (~{0} MB base64) — approaching the wsl argv limit (~ARG_MAX 2 MB)." -f [int]($b64.Length / 1MB))
    }
    # Pass an all-literal command via Invoke-InDistro (NOT Invoke-InDistroScript):
    # the payload is base64 (argv-safe — no $/backslash/quotes), so there's no
    # $VAR to mangle, and we avoid the double-base64 (script body + payload) that
    # Invoke-InDistroScript would impose, halving the argv size. --skip-old-files
    # gives the merge/no-clobber union without a temp dir + cp -an.
    $qDest = ConvertTo-BashQuoted $DestDir
    $tarFlags = if ($Merge) { '--skip-old-files -xz' } else { '-xz' }
    $cmd = "mkdir -p $qDest && printf '%s' '$b64' | base64 -d | tar $tarFlags -C $qDest"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Expand-ArchiveToDistro {
    # Extract a host .tar.gz file's contents into a distro directory as root.
    # -Clean empties the destination first (replace semantics, used by restore).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestDir,
        [switch]$Clean
    )
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Expand-ArchiveToDistro: archive not found: $ArchivePath"
    }
    $bytes = [IO.File]::ReadAllBytes($ArchivePath)
    $b64 = [Convert]::ToBase64String($bytes)
    if ($b64.Length -gt 1MB) {
        Write-Warning ("Expand-ArchiveToDistro: large archive (~{0} MB base64) — approaching the wsl argv limit (~ARG_MAX 2 MB)." -f [int]($b64.Length / 1MB))
    }
    # All-literal argv via Invoke-InDistro (single base64 layer; see Send-TreeToDistro).
    # ConvertTo-BashQuoted wraps the dest in single quotes, so '<dest>'/* globs in
    # bash as <dest>/* for the -Clean wipe. The clean uses ';' (not '&&') so a
    # no-match glob doesn't abort the extract.
    $qDest = ConvertTo-BashQuoted $DestDir
    $cleanPart = if ($Clean) { "rm -rf $qDest/* $qDest/.[!.]* 2>/dev/null; " } else { '' }
    $cmd = "mkdir -p $qDest && ${cleanPart}printf '%s' '$b64' | base64 -d | tar -xz -C $qDest"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Receive-TreeFromDistro {
    # Pull a distro directory's CONTENTS to a host .tar.gz file. Reads as root so
    # it can traverse a 0700 home or a root-owned store. Returns $true on success,
    # $false if the source directory doesn't exist. The host file is a raw
    # gzip'd tar (restore extracts it with Expand-ArchiveToDistro).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestArchivePath
    )
    $qSrc = ConvertTo-BashQuoted $SourceDir
    $cmd = "if [ -d $qSrc ]; then tar -C $qSrc -czf - . | base64 -w0; else exit 2; fi"
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -eq 2) { return $false }
    if ($r.ExitCode -ne 0) {
        throw "Receive-TreeFromDistro: tar failed (exit $($r.ExitCode)) for $SourceDir"
    }
    $b64 = (@($r.Output | ForEach-Object { [string]$_ }) -join '').Trim()
    if (-not $b64) { return $false }
    $bytes = [Convert]::FromBase64String($b64)
    $dir = Split-Path -Parent $DestArchivePath
    [void][System.IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllBytes($DestArchivePath, $bytes)
    return $true
}

function Expand-TarGzToHostDir {
    # Extract a host .tar.gz file's CONTENTS into a host directory (the inverse of
    # the host-side pack in ConvertTo-TarGzBase64 / the host write in
    # Receive-TreeFromDistro). Prefers .NET 8 System.Formats.Tar; falls back to
    # bundled tar.exe on Windows. Used by the one-time shared-store host migration.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Expand-TarGzToHostDir: archive not found: $ArchivePath"
    }
    [void][System.IO.Directory]::CreateDirectory($DestDir)
    if ('System.Formats.Tar.TarFile' -as [type]) {
        $in = [System.IO.File]::OpenRead($ArchivePath)
        try {
            $gz = [System.IO.Compression.GZipStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
            try { [System.Formats.Tar.TarFile]::ExtractToDirectory($gz, $DestDir, $true) }
            finally { $gz.Dispose() }
        }
        finally { $in.Dispose() }
        return
    }
    $tarExe = Join-Path $env:WINDIR 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
        throw 'Expand-TarGzToHostDir: System.Formats.Tar unavailable and no tar.exe fallback found.'
    }
    & $tarExe -xzf $ArchivePath -C $DestDir
    if ($LASTEXITCODE -ne 0) { throw "Expand-TarGzToHostDir: tar.exe extract failed (exit $LASTEXITCODE)" }
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
    # -LiteralPath: same bracket-glob hazard as wsl2-gotchas #19.
    $src = (Resolve-Path -LiteralPath $SourcePath).Path
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

# Pure-managed .xz (LZMA2) decoder, compiled on demand via Add-Type. This is the
# guaranteed fallback so setup never depends on an external xz codec being present
# (7-Zip / xz / Python are only used as faster accelerators when they happen to
# exist). Add-Type ships with PowerShell 7 — it is not an optional dependency.
# Ported from Igor Pavlov's public-domain LZMA reference decoder (LzmaSpec.cpp),
# wrapped with the xz container + LZMA2 chunk framing. See wsl2-gotchas.md #11.
$script:XzDecoderSource = @'
using System;
using System.IO;

namespace Claudearium
{
    // Single-shot .xz -> plain bytes decoder. Instance-per-call (not thread-safe
    // by design; each Decompress() builds a fresh decoder).
    public sealed class XzDecoder
    {
        const int kNumBitModelTotalBits = 11;
        const uint kBitModelTotal = 1u << kNumBitModelTotalBits;
        const int kNumMoveBits = 5;
        const uint kTopValue = 1u << 24;
        const ushort PROB_INIT = (ushort)(kBitModelTotal >> 1);
        const int kNumPosBitsMax = 4;
        const int kNumStates = 12;
        const int kNumLenToPosStates = 4;
        const int kNumAlignBits = 4;
        const int kEndPosModelIndex = 14;
        const int kNumFullDistances = 1 << (kEndPosModelIndex >> 1);
        const uint kMatchMinLen = 2;

        // input (whole compressed file, read into memory for random-access framing)
        byte[] In;
        int InPos;

        // output stream + circular dictionary for back-references
        Stream Out;
        byte[] Dict;
        uint DictSize;
        uint DictPos;
        bool DictFull;

        // range decoder
        uint Range, Code;

        // LZMA params
        int lc, lp, pb;
        uint pbMask, lpMask;

        // symbol state
        uint State;
        uint rep0, rep1, rep2, rep3;
        uint TotalPos;   // uncompressed position since last dictionary reset

        // probability models
        ushort[] LitProbs;
        readonly ushort[] IsMatch     = new ushort[kNumStates << kNumPosBitsMax];
        readonly ushort[] IsRep       = new ushort[kNumStates];
        readonly ushort[] IsRepG0     = new ushort[kNumStates];
        readonly ushort[] IsRepG1     = new ushort[kNumStates];
        readonly ushort[] IsRepG2     = new ushort[kNumStates];
        readonly ushort[] IsRep0Long  = new ushort[kNumStates << kNumPosBitsMax];
        readonly ushort[] PosSlotProbs= new ushort[kNumLenToPosStates << 6]; // 4 trees x 64
        readonly ushort[] SpecPos     = new ushort[1 + kNumFullDistances - kEndPosModelIndex];
        readonly ushort[] AlignProbs  = new ushort[1 << kNumAlignBits];
        // length decoders: [0]=Choice [1]=Choice2, 16 low trees(8), 16 mid trees(8), 1 high tree(256)
        readonly ushort[] LenA        = new ushort[2 + 128 + 128 + 256];
        readonly ushort[] RepLen      = new ushort[2 + 128 + 128 + 256];

        public static void Decompress(string sourcePath, string destPath)
        {
            new XzDecoder().Run(sourcePath, destPath);
        }

        void Run(string sourcePath, string destPath)
        {
            In = File.ReadAllBytes(sourcePath);
            InPos = 0;
            using (var fs = new FileStream(destPath, FileMode.Create, FileAccess.Write))
            using (var bs = new BufferedStream(fs, 1 << 20))
            {
                Out = bs;
                DecodeStream();
                bs.Flush();
            }
        }

        // ---- xz container ----------------------------------------------------
        void DecodeStream()
        {
            // Stream header: 6-byte magic, 2 stream flags, CRC32.
            if (In.Length < 12 ||
                In[0] != 0xFD || In[1] != 0x37 || In[2] != 0x7A ||
                In[3] != 0x58 || In[4] != 0x5A || In[5] != 0x00)
                throw new Exception("not an .xz stream (bad magic)");
            int checkType = In[7] & 0x0F;
            int checkSize = CheckSize(checkType);
            InPos = 12;

            while (true)
            {
                int headerStart = InPos;
                byte b = In[InPos++];
                if (b == 0x00) break;            // 0x00 = Index indicator: blocks are done
                int headerSize = (b + 1) * 4;

                int p = headerStart + 1;
                byte flags = In[p++];
                int numFilters = (flags & 0x03) + 1;
                if ((flags & 0x40) != 0) p = SkipVarint(p);   // compressed size (unused)
                if ((flags & 0x80) != 0) p = SkipVarint(p);   // uncompressed size (unused)

                bool haveLzma2 = false;
                byte dictCode = 0;
                for (int f = 0; f < numFilters; f++)
                {
                    ulong id; p = ReadVarint(p, out id);
                    ulong propSize; p = ReadVarint(p, out propSize);
                    if (id == 0x21) { haveLzma2 = true; if (propSize >= 1) dictCode = In[p]; }
                    p += (int)propSize;
                }
                if (!haveLzma2) throw new Exception("unsupported .xz block: expected an LZMA2 filter");

                InPos = headerStart + headerSize;         // skip header padding + CRC32
                uint blockDict = DecodeDictSize(dictCode);
                int dataStart = InPos;
                DecodeLzma2(blockDict);

                int compLen = InPos - dataStart;
                InPos += (4 - (compLen & 3)) & 3;         // block padding to 4-byte boundary
                InPos += checkSize;                       // integrity check (skipped)
            }
        }

        static int CheckSize(int checkType)
        {
            switch (checkType)
            {
                case 0x00: return 0;   // None
                case 0x01: return 4;   // CRC32
                case 0x04: return 8;   // CRC64 (xz default)
                case 0x0A: return 32;  // SHA-256
                default: throw new Exception("unsupported .xz check type: " + checkType);
            }
        }

        int SkipVarint(int p) { ulong v; return ReadVarint(p, out v); }

        int ReadVarint(int p, out ulong value)
        {
            ulong num = 0; int i = 0;
            while (true)
            {
                byte b = In[p++];
                num |= (ulong)(b & 0x7F) << (i * 7);
                if ((b & 0x80) == 0) break;
                i++;
            }
            value = num;
            return p;
        }

        static uint DecodeDictSize(byte b)
        {
            if (b > 40) throw new Exception("invalid LZMA2 dictionary size code: " + b);
            uint size = (b == 40) ? 0xFFFFFFFF : (uint)((2 | (b & 1)) << (b / 2 + 11));
            // Cap the allocation. Real rootfs dictionaries are <= 64 MiB; a distance
            // beyond the cap would throw a clear error rather than an OOM.
            const uint cap = 512u * 1024 * 1024;
            return size > cap ? cap : size;
        }

        // ---- LZMA2 chunk framing --------------------------------------------
        void DecodeLzma2(uint dictSize)
        {
            while (true)
            {
                byte control = In[InPos++];
                if (control == 0x00) return;              // end of LZMA2 stream

                if (control < 0x80)
                {
                    if (control > 0x02) throw new Exception("invalid LZMA2 control byte: " + control);
                    if (control == 0x01) ResetDict(dictSize);   // uncompressed, reset dict
                    int size = ((In[InPos] << 8) | In[InPos + 1]) + 1; InPos += 2;
                    for (int i = 0; i < size; i++) { PutByte(In[InPos++]); TotalPos++; }
                    continue;
                }

                uint unpackSize = (uint)(((control & 0x1F) << 16) + (In[InPos] << 8) + In[InPos + 1] + 1);
                InPos += 2;
                uint packSize = (uint)((In[InPos] << 8) + In[InPos + 1] + 1);
                InPos += 2;
                int reset = (control >> 5) & 0x03;

                if (reset >= 2) SetProps(In[InPos++]);    // new props (implies state reset)
                if (reset >= 1) ResetState();
                if (reset == 3) ResetDict(dictSize);

                int rcStart = InPos;
                RcInit();
                DecodeLzmaChunk(unpackSize);
                InPos = rcStart + (int)packSize;          // realign to declared pack size
            }
        }

        void SetProps(byte d)
        {
            if (d >= 9 * 5 * 5) throw new Exception("invalid LZMA props byte: " + d);
            lc = d % 9; d /= 9;
            lp = d % 5; pb = d / 5;
            pbMask = (1u << pb) - 1;
            lpMask = (1u << lp) - 1;
            LitProbs = new ushort[0x300 << (lc + lp)];
        }

        void ResetState()
        {
            State = 0; rep0 = rep1 = rep2 = rep3 = 0;
            Fill(IsMatch); Fill(IsRep); Fill(IsRepG0); Fill(IsRepG1); Fill(IsRepG2);
            Fill(IsRep0Long); Fill(PosSlotProbs); Fill(SpecPos); Fill(AlignProbs);
            Fill(LenA); Fill(RepLen);
            if (LitProbs != null) Fill(LitProbs);
        }

        void ResetDict(uint dictSize)
        {
            if (Dict == null || Dict.Length < dictSize) Dict = new byte[dictSize];
            DictSize = dictSize; DictPos = 0; DictFull = false; TotalPos = 0;
        }

        static void Fill(ushort[] a) { for (int i = 0; i < a.Length; i++) a[i] = PROB_INIT; }

        // ---- output / dictionary --------------------------------------------
        void PutByte(byte b)
        {
            Out.WriteByte(b);
            Dict[DictPos++] = b;
            if (DictPos == DictSize) { DictPos = 0; DictFull = true; }
        }

        byte GetByte(uint dist)
        {
            uint i = dist <= DictPos ? DictPos - dist : DictSize - dist + DictPos;
            return Dict[i];
        }

        bool IsEmpty() { return DictPos == 0 && !DictFull; }

        // ---- range decoder ---------------------------------------------------
        void RcInit()
        {
            InPos++;                       // first byte is always 0 (ignored)
            Code = 0;
            for (int i = 0; i < 4; i++) Code = (Code << 8) | In[InPos++];
            Range = 0xFFFFFFFF;
        }

        void Normalize()
        {
            if (Range < kTopValue) { Range <<= 8; Code = (Code << 8) | In[InPos++]; }
        }

        int DecodeBit(ref ushort prob)
        {
            uint v = prob;
            uint bound = (Range >> kNumBitModelTotalBits) * v;
            int sym;
            if (Code < bound) { v += (kBitModelTotal - v) >> kNumMoveBits; Range = bound; sym = 0; }
            else { v -= v >> kNumMoveBits; Code -= bound; Range -= bound; sym = 1; }
            prob = (ushort)v;
            Normalize();
            return sym;
        }

        uint DecodeDirectBits(int numBits)
        {
            uint res = 0;
            do
            {
                Range >>= 1;
                Code -= Range;
                uint t = 0u - (Code >> 31);
                Code += Range & t;
                Normalize();
                res = (res << 1) + t + 1;
            } while (--numBits != 0);
            return res;
        }

        uint BitTree(ushort[] probs, int baseIdx, int numBits)
        {
            uint m = 1;
            for (int i = 0; i < numBits; i++) m = (m << 1) + (uint)DecodeBit(ref probs[baseIdx + m]);
            return m - (1u << numBits);
        }

        uint BitTreeReverse(ushort[] probs, int baseIdx, int numBits)
        {
            uint m = 1, sym = 0;
            for (int i = 0; i < numBits; i++)
            {
                uint bit = (uint)DecodeBit(ref probs[baseIdx + m]);
                m = (m << 1) + bit;
                sym |= bit << i;
            }
            return sym;
        }

        uint DecodeLen(ushort[] L, uint posState)
        {
            if (DecodeBit(ref L[0]) == 0) return BitTree(L, 2 + (int)posState * 8, 3);
            if (DecodeBit(ref L[1]) == 0) return 8 + BitTree(L, 130 + (int)posState * 8, 3);
            return 16 + BitTree(L, 258, 8);
        }

        uint DecodeDistance(uint len)
        {
            uint lenState = len < kNumLenToPosStates ? len : (uint)(kNumLenToPosStates - 1);
            uint posSlot = BitTree(PosSlotProbs, (int)lenState * 64, 6);
            if (posSlot < 4) return posSlot;
            int numDirect = (int)(posSlot >> 1) - 1;
            uint dist = (2u | (posSlot & 1)) << numDirect;
            if (posSlot < kEndPosModelIndex)
                dist += BitTreeReverse(SpecPos, (int)dist - (int)posSlot, numDirect);
            else
            {
                dist += DecodeDirectBits(numDirect - kNumAlignBits) << kNumAlignBits;
                dist += BitTreeReverse(AlignProbs, 0, kNumAlignBits);
            }
            return dist;
        }

        // ---- LZMA symbol loop ------------------------------------------------
        void DecodeLzmaChunk(uint unpackSize)
        {
            uint end = TotalPos + unpackSize;
            while (TotalPos < end)
            {
                uint posState = TotalPos & pbMask;
                if (DecodeBit(ref IsMatch[(State << kNumPosBitsMax) + posState]) == 0)
                {
                    byte prevByte = IsEmpty() ? (byte)0 : GetByte(1);
                    uint litState = ((TotalPos & lpMask) << lc) + ((uint)prevByte >> (8 - lc));
                    int off = 0x300 * (int)litState;
                    uint symbol = 1;
                    if (State >= 7)
                    {
                        uint matchByte = GetByte(rep0 + 1);
                        do
                        {
                            uint matchBit = (matchByte >> 7) & 1; matchByte <<= 1;
                            uint bit = (uint)DecodeBit(ref LitProbs[off + (int)(((1 + matchBit) << 8) + symbol)]);
                            symbol = (symbol << 1) | bit;
                            if (matchBit != bit) break;
                        } while (symbol < 0x100);
                    }
                    while (symbol < 0x100) symbol = (symbol << 1) | (uint)DecodeBit(ref LitProbs[off + (int)symbol]);
                    PutByte((byte)symbol); TotalPos++;
                    State = State < 4 ? 0u : (State < 10 ? State - 3 : State - 6);
                    continue;
                }

                uint len;
                if (DecodeBit(ref IsRep[State]) != 0)
                {
                    if (IsEmpty()) throw new Exception("corrupt .xz: rep match with empty dictionary");
                    if (DecodeBit(ref IsRepG0[State]) == 0)
                    {
                        if (DecodeBit(ref IsRep0Long[(State << kNumPosBitsMax) + posState]) == 0)
                        {
                            State = State < 7 ? 9u : 11u;
                            PutByte(GetByte(rep0 + 1)); TotalPos++;
                            continue;
                        }
                    }
                    else
                    {
                        uint dist;
                        if (DecodeBit(ref IsRepG1[State]) == 0) dist = rep1;
                        else
                        {
                            if (DecodeBit(ref IsRepG2[State]) == 0) dist = rep2;
                            else { dist = rep3; rep3 = rep2; }
                            rep2 = rep1;
                        }
                        rep1 = rep0; rep0 = dist;
                    }
                    len = DecodeLen(RepLen, posState);
                    State = State < 7 ? 8u : 11u;
                }
                else
                {
                    rep3 = rep2; rep2 = rep1; rep1 = rep0;
                    len = DecodeLen(LenA, posState);
                    State = State < 7 ? 7u : 10u;
                    rep0 = DecodeDistance(len);
                    if (rep0 == 0xFFFFFFFF) return;   // end-of-stream marker
                    if (rep0 >= DictSize || (!DictFull && rep0 >= DictPos))
                        throw new Exception("corrupt .xz: distance out of range");
                }

                len += kMatchMinLen;
                if (TotalPos + len > end) len = end - TotalPos;   // guard against corruption
                for (uint i = 0; i < len; i++) PutByte(GetByte(rep0 + 1));
                TotalPos += len;
            }
        }
    }
}
'@

function Initialize-XzDecoderType {
    # Compile the managed decoder once per session. Add-Type throws if the type
    # already exists, so guard on the resolved type name.
    if ('Claudearium.XzDecoder' -as [type]) { return }
    Add-Type -TypeDefinition $script:XzDecoderSource -Language CSharp
}

function Expand-XzManaged {
    # Pure-managed .xz -> plain-file decompression. No external tool required.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )
    Initialize-XzDecoderType
    $src = (Resolve-Path -LiteralPath $SourcePath).Path
    [Claudearium.XzDecoder]::Decompress($src, $DestPath)
    if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
        throw "managed xz decompression produced no output at $DestPath"
    }
}

function Expand-Xz {
    # Prefer a fast external xz codec when one happens to be installed, but always
    # fall back to the pure-managed decoder so setup never depends on 7-Zip / xz /
    # Python being present (wsl2-gotchas #11).
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

    # 2. Python's lzma module — when a stock Python 3 is on PATH. Its native
    #    liblzma is ~2.5x faster than the managed decoder below. Optional: absent
    #    Python simply falls through to the guaranteed managed path.
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

    # 3. Pure-managed decoder — always available, no external tool needed. This is
    #    the guaranteed fallback; 7-Zip and Python above are just faster when present.
    Write-Host "  Decompressing via built-in managed xz decoder..."
    Expand-XzManaged -SourcePath $SourcePath -DestPath $DestPath
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
    ConvertTo-TarGzBase64, `
    Send-TreeToDistro, `
    Expand-ArchiveToDistro, `
    Receive-TreeFromDistro, `
    Expand-TarGzToHostDir, `
    Resolve-LatestDebianRootfsUrl, `
    Save-Rootfs, `
    Convert-RootfsToTar, `
    Expand-Gzip, `
    Expand-Xz, `
    Expand-XzManaged
