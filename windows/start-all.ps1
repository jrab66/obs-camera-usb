# Start the whole streaming stack: MediaMTX server + camera push + OBS.
# Run manually, or register it to run at logon with setup-autologin.ps1.

# Set to $false on a camera-only box (OBS running on a different machine).
$StartObs = $true

# Where OBS is installed (default install path). Edit if yours differs.
$ObsExe = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
# --disable-shutdown-check skips the "safe mode?" prompt after an unclean
# shutdown, which would otherwise block unattended startup. Other useful
# flags: --startstreaming --startrecording --startvirtualcam --minimize-to-tray
$ObsArgs = @("--disable-shutdown-check")

Set-Location $PSScriptRoot

# 1. Start the RTMP/RTSP server: native mediamtx.exe if present, else Docker.
if (Test-Path "$PSScriptRoot\mediamtx.exe") {
    if (-not (Get-Process -Name mediamtx -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "$PSScriptRoot\mediamtx.exe" -ArgumentList "mediamtx.yml" `
            -WorkingDirectory $PSScriptRoot -WindowStyle Minimized
    }
} else {
    docker compose up -d
}

# 2. Wait for the server to listen (Docker Desktop can take a while after boot).
$serverUp = $false
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    try {
        (New-Object Net.Sockets.TcpClient("localhost", 1935)).Close()
        $serverUp = $true
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}
if (-not $serverUp) {
    Write-Host "[start-all] ERROR: server not listening on 1935 after 180s. Is Docker Desktop set to start at login?"
    exit 1
}

# 3. Start the camera push in its own minimized window (has its own retry loop).
Start-Process powershell -WindowStyle Minimized -ArgumentList `
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSScriptRoot\start-camera.ps1`""

# 4. Start OBS. Working directory must be OBS's own folder or it fails to start.
if (-not $StartObs) {
    Write-Host "[start-all] done: server up, camera pushing (OBS disabled on this box)."
    exit 0
}
if (Test-Path $ObsExe) {
    if (-not (Get-Process -Name obs64 -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $ObsExe -ArgumentList $ObsArgs -WorkingDirectory (Split-Path $ObsExe)
    }
} else {
    Write-Host "[start-all] OBS not found at $ObsExe - edit `$ObsExe at the top of this script."
}

Write-Host "[start-all] done: server up, camera pushing, OBS launched."
