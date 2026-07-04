# One-time setup for an unattended streaming PC. Run as Administrator.
# Does two things:
#   1. Configures Windows to log this user in automatically at boot.
#   2. Registers start-all.ps1 to run at logon (scheduled task), so a reboot
#      ends with the server, camera push, and OBS all running.
#
# SECURITY WARNING: the auto-login password is stored in the registry in
# PLAIN TEXT, readable by anyone with access to this machine. Acceptable for
# a dedicated streaming box on a trusted LAN; NOT for a personal PC. The safer
# alternative is Sysinternals Autologon, which stores it encrypted:
# https://learn.microsoft.com/sysinternals/downloads/autologon
# (If you use Autologon instead, this script still registers the startup task —
# just answer "n" to the auto-login question.)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[setup] ERROR: run this from an elevated PowerShell (Run as Administrator)."
    exit 1
}

$user = $env:USERNAME

# --- 1. Auto-login ------------------------------------------------------------
$answer = Read-Host "Configure auto-login for user '$user'? Password will be stored in plain text (y/n)"
if ($answer -eq "y") {
    $pass = Read-Host "Password for $user"
    $rk = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $rk -Name AutoAdminLogon   -Value "1" -Type String
    Set-ItemProperty -Path $rk -Name DefaultUserName  -Value $user -Type String
    Set-ItemProperty -Path $rk -Name DefaultPassword  -Value $pass -Type String
    Set-ItemProperty -Path $rk -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
    Write-Host "[setup] Auto-login enabled for $user."
    Write-Host "[setup] To undo later: set AutoAdminLogon to 0 and delete DefaultPassword under"
    Write-Host "[setup] HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
} else {
    Write-Host "[setup] Skipped auto-login."
}

# --- 2. Run start-all.ps1 at logon ---------------------------------------------
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$PSScriptRoot\start-all.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0)
Register-ScheduledTask -TaskName "obs-camera-usb-startup" -Action $action -Trigger $trigger `
    -Settings $settings -Force | Out-Null
Write-Host "[setup] Scheduled task 'obs-camera-usb-startup' registered: start-all.ps1 runs at logon."
Write-Host "[setup] To remove it: Unregister-ScheduledTask -TaskName obs-camera-usb-startup"
Write-Host "[setup] Done. Reboot to test the full chain."
