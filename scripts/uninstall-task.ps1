#requires -Version 5.1
<#
.SYNOPSIS
    Usuwa task MaturyBlog-Daily z Windows Task Scheduler.
#>

$ErrorActionPreference = 'Stop'

$TaskName = 'MaturyBlog-Daily'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "Task '$TaskName' is not registered. Nothing to do."
    exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "OK Task '$TaskName' removed."
