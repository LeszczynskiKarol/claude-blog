#requires -Version 5.1
<#
.SYNOPSIS
    Rejestruje task w Windows Task Scheduler odpalający scripts/run-daily.ps1
    codziennie o 06:00.

.DESCRIPTION
    Uruchom JEDNORAZOWO. Nie wymaga uprawnień admina jesli task ma dzialac
    tylko dla biezacego uzytkownika.

.NOTES
    Test od razu (bez czekania na 06:00):
        Start-ScheduledTask -TaskName 'MaturyBlog-Daily'

    Status:
        Get-ScheduledTask -TaskName 'MaturyBlog-Daily' | Get-ScheduledTaskInfo

    Usuniecie:
        powershell -File scripts/uninstall-task.ps1

    Zmiana godziny:
        - taskschd.msc -> prawo-klik -> Properties -> Triggers
        - albo edytuj $TriggerTime ponizej i odpal install-task.ps1 ponownie
#>

$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ScriptPath = Join-Path $ProjectDir 'scripts\run-daily.ps1'
$TaskName = 'MaturyBlog-Daily'
$TriggerTime = '06:00'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "run-daily.ps1 not found at: $ScriptPath"
    exit 1
}

$Action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $ProjectDir

$Trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$Principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description 'Daily auto-run of Claude Code blog post generator (project: claude-blog)' `
    -Force | Out-Null

Write-Host ""
Write-Host "OK Task registered: $TaskName"
Write-Host "   Trigger: daily at $TriggerTime"
Write-Host "   Script:  $ScriptPath"
Write-Host "   Logs:    $ProjectDir\logs\run-YYYY-MM-DD.log"
Write-Host ""
Write-Host "Test now without waiting:"
Write-Host "   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host ""
Write-Host "Check status:"
Write-Host "   Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host ""
Write-Host "Uninstall:"
Write-Host "   powershell -File scripts\uninstall-task.ps1"
