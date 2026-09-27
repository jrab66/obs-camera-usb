# Registers watch-emeet-obs.ps1 as a scheduled task: every 5 minutes, starting
# 3 minutes after logon (so start-all.ps1 / start-obs.ps1 go first).
# Runs as the logged-on user, only while logged on, so anything it starts
# (EMEET Studio, OBS) lands in the console session. Run from an elevated
# PowerShell in windows\.
#
# Remove: Unregister-ScheduledTask -TaskName obs-camera-usb-watcher

param(
    [int]$IntervalMinutes = 5
)

$script = Join-Path $PSScriptRoot "watch-emeet-obs.ps1"
if (-not (Test-Path $script)) {
    Write-Host "[setup] ERROR: watch-emeet-obs.ps1 not found next to this script."
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[setup] ERROR: run this from an elevated PowerShell (Run as Administrator)."
    exit 1
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = "PT3M"
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)).Repetition
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
Register-ScheduledTask -TaskName "obs-camera-usb-watcher" -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "[setup] Scheduled task 'obs-camera-usb-watcher' registered: every $IntervalMinutes min, from 3 min after logon."
Write-Host "[setup] Log: $env:LOCALAPPDATA\obs-camera-usb\watcher.log"
Write-Host "[setup] Start it now without logging off: Start-ScheduledTask -TaskName obs-camera-usb-watcher"
Write-Host "[setup] To remove it: Unregister-ScheduledTask -TaskName obs-camera-usb-watcher"
