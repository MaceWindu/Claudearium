# ClaudeFile.psm1
# Manages the account-level CLAUDE.md inside the distro at
# /home/claude/.claude/CLAUDE.md. Driven by profile.claudeFile, which picks one
# of three modes:
#   - host-copy    — copy from $env:USERPROFILE\.claude\CLAUDE.md
#   - caveman-lite — write a literal "be brief." one-liner
#   - custom-path  — copy from claudeFile.path (a Windows file path)
# Setup offers an interactive prompt when the block is absent; reconcile picks
# up drift afterwards (string compare of rendered content vs distro file).
#
# Public surface:
#   Test-HostClaudeAvailable                      — is `claude` on host PATH?
#   Get-HostClaudeFilePath                        — $env:USERPROFILE\.claude\CLAUDE.md
#   Get-ClaudeFileDesiredContent -Spec <h>        — render the file body per mode (LF-normalized)
#   Get-ClaudeFileActualFromDistro -DistroName    — returns string content or $null if absent
#   Install-ClaudeFile -DistroName -Spec <h>      — write + chown + chmod (mirrors Install-ClaudeSettings)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')

function Test-HostClaudeAvailable {
    # The host-copy option is only offered when `claude` is actually installed
    # on the host — picking up a stray ~/.claude/CLAUDE.md without the CLI is
    # almost always wrong.
    [CmdletBinding()] param()
    return [bool](Get-Command claude -ErrorAction SilentlyContinue)
}

function Get-HostClaudeFilePath {
    [CmdletBinding()] param()
    if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set; cannot resolve host CLAUDE.md.' }
    return (Join-Path $env:USERPROFILE '.claude\CLAUDE.md')
}

function Get-ClaudeFileDesiredContent {
    # Render the file body for the configured mode. CRLF/CR are normalized to LF
    # so that drift detection compares apples to apples against the distro file
    # (which we always write LF-only via Install-ClaudeFile).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Spec)
    if (-not $Spec.ContainsKey('mode')) { throw 'claudeFile.mode is required.' }
    $mode = [string]$Spec.mode
    $raw = switch ($mode) {
        'caveman-lite' { "be brief.`n" }
        'host-copy'    {
            $hp = Get-HostClaudeFilePath
            if (-not (Test-Path -LiteralPath $hp)) {
                throw "claudeFile.mode = host-copy but host file not found: $hp"
            }
            [string](Get-Content -LiteralPath $hp -Raw)
        }
        'custom-path'  {
            if (-not $Spec.ContainsKey('path') -or [string]::IsNullOrWhiteSpace([string]$Spec.path)) {
                throw 'claudeFile.path is required when mode = custom-path.'
            }
            $p = [string]$Spec.path
            if (-not (Test-Path -LiteralPath $p)) {
                throw "claudeFile.path not found: $p"
            }
            [string](Get-Content -LiteralPath $p -Raw)
        }
        default        { throw "claudeFile.mode '$mode' is not valid (expected: host-copy / caveman-lite / custom-path)." }
    }
    # Normalize on a local var first — gotcha #14 (chained -replace inside a
    # method-arg list gets parsed as a multi-arg method call).
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    return $normalized
}

function Get-ClaudeFileActualFromDistro {
    # Returns the LF-joined contents of /home/claude/.claude/CLAUDE.md or $null
    # if the file is absent. Distinguishes 'missing' from 'empty' by the cat
    # exit code: missing -> $null, empty -> ''.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'claude' `
        -Command 'cat /home/claude/.claude/CLAUDE.md' -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $null }
    return (@($r.Output | ForEach-Object { [string]$_ }) -join "`n")
}

function Install-ClaudeFile {
    # Write the rendered content to /home/claude/.claude/CLAUDE.md as root, then
    # chown claude:claude + chmod 0644. Base64-transport mirrors
    # Install-ClaudeSettings so we don't fight argv mangling.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$Spec
    )
    $content = Get-ClaudeFileDesiredContent -Spec $Spec
    # Already LF-normalized by Get-ClaudeFileDesiredContent — encode straight to
    # bytes. Assign to a local first (gotcha #14) so the [Text.Encoding] call
    # below has exactly one positional arg.
    $payload = $content
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $cmd = "set -e; mkdir -p /home/claude/.claude; " +
           "printf '%s' '$b64' | base64 -d > /home/claude/.claude/CLAUDE.md; " +
           "chown -R claude:claude /home/claude/.claude; " +
           "chmod 0644 /home/claude/.claude/CLAUDE.md"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

Export-ModuleMember -Function `
    Test-HostClaudeAvailable, `
    Get-HostClaudeFilePath, `
    Get-ClaudeFileDesiredContent, `
    Get-ClaudeFileActualFromDistro, `
    Install-ClaudeFile
