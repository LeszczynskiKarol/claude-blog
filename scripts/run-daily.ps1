#requires -Version 5.1
<#
.SYNOPSIS
    Odpala Claude Code w trybie non-interactive z promptem 'dalej'.
    Loguje do logs/run-YYYY-MM-DD.log.
    Wysyła powiadomienie Slack przy napisaniu nowego posta lub przy błędzie
    (jeśli .slack-webhook jest skonfigurowany).

.DESCRIPTION
    Działa jako Task Scheduler trigger. Non-interactive.
    Wymaga: Claude Code CLI, ręcznie zalogowane CC (token cached).
    Opcjonalnie: .slack-webhook w korzeniu projektu z URL webhooka.

.NOTES
    Test ręczny:
        powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-daily.ps1
#>

$ErrorActionPreference = 'Continue'

# Project root = parent of scripts/
$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$LogDir = Join-Path $ProjectDir 'logs'
$Today = Get-Date -Format 'yyyy-MM-dd'
$LogFile = Join-Path $LogDir "run-$Today.log"

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

Set-Location -Path $ProjectDir

# Load Slack notification helpers
. (Join-Path $PSScriptRoot 'notify-slack.ps1')

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$stamp] $Message" -Encoding UTF8
}

function Get-PublishedPosts {
    param([string]$IndexPath)
    if (-not (Test-Path $IndexPath)) {
        return @()
    }
    try {
        $idx = Get-Content -Path $IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $idx.posts) {
            return @()
        }
        $names = @()
        foreach ($prop in $idx.posts.PSObject.Properties) {
            $names += $prop.Name
        }
        return $names
    }
    catch {
        Write-Log "WARN: failed to parse _index.json: $_"
        return @()
    }
}

Write-Log "=== Run started ==="
Write-Log "ProjectDir: $ProjectDir"

# Sanity: claude on PATH?
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    $msg = "'claude' not found on PATH. Aborting."
    Write-Log "ERROR: $msg"
    Send-SlackError -Message $msg -ProjectDir $ProjectDir -LogPath $LogFile
    exit 1
}
Write-Log "Claude binary: $($claudeCmd.Source)"

# Snapshot: which posts are published BEFORE this run
$IndexPath = Join-Path $ProjectDir '_index.json'
$publishedBefore = Get-PublishedPosts -IndexPath $IndexPath
Write-Log "Published BEFORE run: $($publishedBefore.Count) posts"

# Run Claude Code non-interactive
Write-Log "--- claude -p 'dalej' ---"

$claudeExitCode = 0
try {
    $output = & claude -p "dalej" `
        --permission-mode bypassPermissions `
        --output-format text 2>&1

    foreach ($line in $output) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }

    $claudeExitCode = $LASTEXITCODE
    Write-Log "--- claude exited with code $claudeExitCode ---"
}
catch {
    $errMsg = "claude invocation threw exception: $_"
    Write-Log "EXCEPTION: $errMsg"
    Write-Log "Stack: $($_.ScriptStackTrace)"
    Send-SlackError -Message $errMsg -ProjectDir $ProjectDir -LogPath $LogFile
    exit 1
}

if ($claudeExitCode -ne 0) {
    $msg = "claude exited with non-zero code: $claudeExitCode. See log: $LogFile"
    Write-Log "ERROR: $msg"
    Send-SlackError -Message $msg -ProjectDir $ProjectDir -LogPath $LogFile
    # continue — check if anything got published despite the error
}

# Snapshot: which posts are published AFTER this run
$publishedAfter = Get-PublishedPosts -IndexPath $IndexPath
Write-Log "Published AFTER run: $($publishedAfter.Count) posts"

# Diff: newly published in this run
$newlyPublished = $publishedAfter | Where-Object { $_ -notin $publishedBefore }

if ($newlyPublished.Count -gt 0) {
    Write-Log "Newly published this run: $($newlyPublished -join ', ')"

    # Hero images are now chosen DURING post generation by the Claude session
    # itself (it views Pexels candidates with its own vision — on the
    # subscription, not paid API — and writes heroImage* into the .md
    # frontmatter via /api/internal/store-blog-image). See CLAUDE.md §Zdjęcie.
    # So there is no separate API-vision image step here anymore.

    foreach ($slug in $newlyPublished) {
        Write-Log "Sending Slack new-post notification for: $slug"
        Send-SlackNewPost -PostSlug $slug -ProjectDir $ProjectDir
    }
} else {
    Write-Log "No newly published posts in this run."
}

Write-Log "=== Run ended ==="
Add-Content -Path $LogFile -Value "" -Encoding UTF8

exit $claudeExitCode
