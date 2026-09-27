# Registers watch-emeet-obs.ps1 as a scheduled task that runs every 5 minutes
# starting now (so no logon is needed after install), plus once 3 minutes
# after each logon (so start-all.ps1 / start-obs.ps1 go first). Runs as the
# logged-on user, only while logged on (same as obs-camera-usb-startup), so
# anything it starts (EMEET Studio, OBS) lands in the console session. Run
# from an elevated PowerShell in windows\.
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

$user = $env:USERNAME
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$every = New-TimeSpan -Minutes $IntervalMinutes
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$atLogon.Delay = "PT3M"
# Only the time trigger repeats (it keeps repeating across reboots); a
# repeating logon trigger too would run the watcher twice per interval.
$fromNow = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval $every
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
try {
    Register-ScheduledTask -TaskName "obs-camera-usb-watcher" -Action $action -Trigger @($atLogon, $fromNow) `
        -Settings $settings -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host "[setup] ERROR: could not register the task: $($_.Exception.Message)"
    exit 1
}

Write-Host "[setup] Scheduled task 'obs-camera-usb-watcher' registered: every $IntervalMinutes min, from now and from 3 min after each logon."
Write-Host "[setup] Log: $env:LOCALAPPDATA\obs-camera-usb\watcher.log"
Write-Host "[setup] Start it now without logging off: Start-ScheduledTask -TaskName obs-camera-usb-watcher"
Write-Host "[setup] To remove it: Unregister-ScheduledTask -TaskName obs-camera-usb-watcher"
