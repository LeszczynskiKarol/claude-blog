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

# ── Image-picking env for the Claude session (zero-config) ─────────────────
# The blog session needs MATURY_API_BASE + MATURY_API_BEARER to fetch + view
# Pexels candidates and store the chosen hero image. Single source of truth:
# read the bearer straight from the matury-online backend .env on this machine
# (same value as INTERNAL_API_BEARER). No manual env setup, no secret in repo.
$MaturyRepo = 'D:\matury-online.pl'
$MaturyEnv = Join-Path $MaturyRepo 'backend\.env'
$env:MATURY_API_BASE = 'https://www.matury-online.pl'
if (Test-Path $MaturyEnv) {
    $bearerLine = Get-Content $MaturyEnv | Where-Object { $_ -match '^INTERNAL_API_BEARER=' } | Select-Object -First 1
    if ($bearerLine) {
        $env:MATURY_API_BEARER = ($bearerLine -replace '^INTERNAL_API_BEARER=', '').Trim().Trim('"').Trim("'")
        Write-Log "Image env: MATURY_API_BASE set, MATURY_API_BEARER loaded from backend/.env"
    } else {
        Write-Log "WARN: INTERNAL_API_BEARER not found in $MaturyEnv — posts will have no image"
    }
} else {
    Write-Log "WARN: $MaturyEnv not found — posts will have no image"
}

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

    # Hero images are chosen DURING post generation by the Claude session itself
    # (views Pexels candidates with its own vision — subscription, not paid API —
    # and writes heroImage* into the .md frontmatter). See CLAUDE.md §6.5.

    # ── AUTO-PUBLISH: commit + push new posts to the matury-online repo ─────
    # Blog posts land in D:\matury-online.pl\frontend\src\content\blog. They only
    # go live after a push (push → GitHub Actions deploy). Do it automatically so
    # the whole pipeline (write → image → publish) runs unattended.
    try {
        $blogRel = "frontend/src/content/blog"
        $added = 0
        foreach ($slug in $newlyPublished) {
            $mdRel = "$blogRel/$slug.md"
            if (Test-Path (Join-Path $MaturyRepo $mdRel)) {
                & git -C $MaturyRepo add -- $mdRel
                $added++
            } else {
                Write-Log "WARN: expected post file not found: $mdRel"
            }
        }
        if ($added -gt 0) {
            $commitMsg = "content(blog): auto-publish " + ($newlyPublished -join ', ')
            & git -C $MaturyRepo commit -m $commitMsg 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value "  [git] $_" -Encoding UTF8 }
            if ($LASTEXITCODE -eq 0) {
                & git -C $MaturyRepo push origin main 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value "  [git] $_" -Encoding UTF8 }
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Auto-published $added post(s) → push OK (deploy triggered)"
                } else {
                    Write-Log "ERROR: git push failed (code $LASTEXITCODE) — posts committed locally, not live"
                    Send-SlackError -Message "Blog auto-publish: git push failed" -ProjectDir $ProjectDir -LogPath $LogFile
                }
            } else {
                Write-Log "git commit returned $LASTEXITCODE (nothing to commit?)"
            }
        }
    }
    catch {
        Write-Log "EXCEPTION during auto-publish: $_"
        Send-SlackError -Message "Blog auto-publish exception: $_" -ProjectDir $ProjectDir -LogPath $LogFile
    }

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
