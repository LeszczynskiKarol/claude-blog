#requires -Version 5.1
<#
.SYNOPSIS
    Moduł powiadomień Slack dla claude-blog.

.DESCRIPTION
    Dot-source z innych skryptów:
        . "$PSScriptRoot\notify-slack.ps1"

    Funkcje:
        Get-SlackWebhook                       # zwraca URL z pliku .slack-webhook lub $null
        Send-SlackMessage -Text "..."          # basic message
        Send-SlackNewPost -PostSlug <slug> -ProjectDir <path>
        Send-SlackError -Message "..." -ProjectDir <path>

    Webhook URL czytany z <ProjectDir>\.slack-webhook (pierwsza linia, trim).
    Jeśli plik nie istnieje lub jest pusty — funkcje milczą (no-op).
#>

function Get-SlackWebhook {
    param([string]$ProjectDir)

    $webhookFile = Join-Path $ProjectDir '.slack-webhook'
    if (-not (Test-Path $webhookFile)) {
        return $null
    }
    $url = (Get-Content -Path $webhookFile -TotalCount 1 -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        return $null
    }
    if ($url -notmatch '^https://hooks\.slack\.com/services/') {
        Write-Warning ".slack-webhook contains invalid URL (must start with https://hooks.slack.com/services/)"
        return $null
    }
    return $url
}

function Send-SlackMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ProjectDir,
        [array]$Blocks = $null
    )

    $url = Get-SlackWebhook -ProjectDir $ProjectDir
    if (-not $url) {
        return $false
    }

    $payload = @{ text = $Text }
    if ($Blocks) {
        $payload.blocks = $Blocks
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress

    try {
        $resp = Invoke-RestMethod `
            -Uri $url `
            -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
            -TimeoutSec 15
        return $true
    }
    catch {
        Write-Warning "Slack POST failed: $_"
        return $false
    }
}

function Send-SlackNewPost {
    param(
        [Parameter(Mandatory)][string]$PostSlug,
        [Parameter(Mandatory)][string]$ProjectDir
    )

    $indexPath = Join-Path $ProjectDir '_index.json'
    $topicsPath = Join-Path $ProjectDir 'blog_topics.json'

    if (-not (Test-Path $indexPath)) {
        Write-Warning "_index.json not found, skipping notification"
        return
    }

    $index = Get-Content -Path $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $index.posts.$PostSlug

    if (-not $entry) {
        Write-Warning "Post '$PostSlug' not found in _index.json"
        return
    }

    $title = $entry.title
    $cluster = $entry.cluster
    $category = $entry.category
    $subject = $entry.subjectSlug
    $wordCount = $entry.wordCount
    $filePath = $entry.filePath
    $linkCount = if ($entry.internalLinksOut) { $entry.internalLinksOut.Count } else { 0 }

    # Read pending count from blog_topics.json
    $pendingTotal = 0
    $pendingP10 = 0
    if (Test-Path $topicsPath) {
        try {
            $topics = Get-Content -Path $topicsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $pendingItems = $topics.topics | Where-Object { $_.status -eq 'pending' }
            $pendingTotal = $pendingItems.Count
            $pendingP10 = ($pendingItems | Where-Object { $_.priority -ge 9 }).Count
        } catch {}
    }

    # Public URL on the live site
    $publicUrl = "https://www.matury-online.pl/blog/$PostSlug"

    $text = ":memo: Nowy post na blogu: *$title*"

    $detailsLines = @(
        "*Tytul:* $title",
        "*Slug:* ``$PostSlug``",
        "*Klaster:* $cluster | *Kategoria:* $category" + $(if ($subject) { " | *Przedmiot:* $subject" } else { "" }),
        "*Slow:* $wordCount | *Linkow wewn.:* $linkCount",
        "*Plik:* ``$filePath``",
        "*URL (po deploy):* $publicUrl",
        "",
        "*Kolejka:* $pendingTotal pending ($pendingP10 z priority>=9)"
    )

    $blocks = @(
        @{
            type = "header"
            text = @{
                type = "plain_text"
                text = ":memo: Nowy post wygenerowany"
                emoji = $true
            }
        },
        @{
            type = "section"
            text = @{
                type = "mrkdwn"
                text = ($detailsLines -join "`n")
            }
        }
    )

    Send-SlackMessage `
        -Text $text `
        -Blocks $blocks `
        -ProjectDir $ProjectDir | Out-Null
}

function Send-SlackError {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$LogPath = ""
    )

    $hostName = [System.Net.Dns]::GetHostName()
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $text = ":rotating_light: claude-blog FAIL on $hostName"

    $details = @(
        "*Host:* $hostName",
        "*Time:* $stamp",
        "*Error:* $Message"
    )
    if ($LogPath -and (Test-Path $LogPath)) {
        $details += "*Log:* ``$LogPath``"
    }

    $blocks = @(
        @{
            type = "header"
            text = @{
                type = "plain_text"
                text = ":rotating_light: Blog task FAILED"
                emoji = $true
            }
        },
        @{
            type = "section"
            text = @{
                type = "mrkdwn"
                text = ($details -join "`n")
            }
        }
    )

    Send-SlackMessage `
        -Text $text `
        -Blocks $blocks `
        -ProjectDir $ProjectDir | Out-Null
}
