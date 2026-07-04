# OBS PC (subscriber) in a two-machine setup: wait until the camera box is
# serving, then launch OBS with its Media Source pointing at
# rtsp://<camera-box-ip>:8554/cam (configure the source inside OBS once).
#
# Register at logon with:  .\setup-autologin.ps1 -StartupScript start-obs.ps1

# IP of the camera box (the PC running start-all.ps1). Edit this.
$CameraBoxIp = "192.168.1.50"

# Where OBS is installed (default install path). Edit if yours differs.
$ObsExe = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
# Add --startstreaming / --startrecording / --startvirtualcam to go live automatically.
$ObsArgs = @("--disable-shutdown-check")

# Wait for the camera box RTSP port so OBS doesn't open onto a dead source
# (up to 3 min - the camera box may still be booting).
$serverUp = $false
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    try {
        (New-Object Net.Sockets.TcpClient($CameraBoxIp, 8554)).Close()
        $serverUp = $true
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}
if (-not $serverUp) {
    Write-Host "[start-obs] WARNING: $CameraBoxIp:8554 not reachable after 180s - launching OBS anyway."
    Write-Host "[start-obs] The Media Source will connect once the camera box is up (enable 'Restart playback when source becomes active')."
}

if (-not (Test-Path $ObsExe)) {
    Write-Host "[start-obs] ERROR: OBS not found at $ObsExe - edit `$ObsExe at the top of this script."
    exit 1
}
if (-not (Get-Process -Name obs64 -ErrorAction SilentlyContinue)) {
    # Working directory must be OBS's own folder or it fails to start.
    Start-Process -FilePath $ObsExe -ArgumentList $ObsArgs -WorkingDirectory (Split-Path $ObsExe)
}
Write-Host "[start-obs] done: OBS launched (camera box reachable: $serverUp)."
