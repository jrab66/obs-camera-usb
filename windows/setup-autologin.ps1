# One-time setup for an unattended streaming PC. Run as Administrator.
# Does two things:
#   1. Enables Windows auto-login via Sysinternals Autologon — the password is
#      stored encrypted as an LSA secret, NOT in plain text. Autologon64.exe is
#      downloaded automatically from live.sysinternals.com if not found.
#   2. Registers start-all.ps1 to run at logon (scheduled task), so a reboot
#      ends with the server, camera push, and OBS all running.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[setup] ERROR: run this from an elevated PowerShell (Run as Administrator)."
    exit 1
}

$user = $env:USERNAME

# --- 1. Auto-login via Sysinternals Autologon ----------------------------------
$autologon = Join-Path $PSScriptRoot "Autologon64.exe"
if (-not (Test-Path $autologon)) {
    $found = Get-Command "Autologon64.exe", "Autologon.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $autologon = $found.Source }
}
if (-not (Test-Path $autologon)) {
    Write-Host "[setup] Autologon not found — downloading from live.sysinternals.com..."
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon64.exe" -OutFile $autologon
    Write-Host "[setup] Saved to $autologon"
}

$answer = Read-Host "Enable auto-login for user '$user'? (y/n)"
if ($answer -eq "y") {
    $secure = Read-Host "Password for $user" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    & $autologon /accepteula $user $env:COMPUTERNAME $plain
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[setup] Auto-login enabled (password stored encrypted as an LSA secret)."
    } else {
        Write-Host "[setup] WARNING: Autologon exited with code $LASTEXITCODE — check the password."
    }
    Write-Host "[setup] To disable later: run Autologon64.exe and click Disable."
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
