# Push a USB camera into the MediaMTX server over RTMP.
# Run AFTER starting the server (`docker compose up -d` or `.\mediamtx.exe mediamtx.yml`).
# Requires ffmpeg on PATH (winget install ffmpeg).
#
# Set this to your camera's exact DirectShow name — see README.md "Identify your USB camera".
$CameraName = "UVC Camera"

# Match these to a mode your camera supports (README: "List supported modes").
$Width = 1280
$Height = 720
$Fps = 30

# --- Pre-flight checks: fail loudly instead of blind-looping -----------------

# 1. Does the camera exist? List DirectShow video devices and compare.
$dshowOutput = ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
$videoDevices = [regex]::Matches($dshowOutput, '"([^"]+)"\s+\(video\)') |
    ForEach-Object { $_.Groups[1].Value }

if (-not $videoDevices) {
    Write-Host "[start-camera] ERROR: no video devices found at all. Is the camera plugged in?"
    exit 1
}
if ($videoDevices -notcontains $CameraName) {
    Write-Host "[start-camera] ERROR: no camera named `"$CameraName`" found."
    Write-Host "[start-camera] Available video devices:"
    $videoDevices | ForEach-Object { Write-Host "  - `"$_`"" }
    Write-Host "[start-camera] Edit `$CameraName at the top of this script to match one exactly."
    exit 1
}

# 2. Is the RTMP server up?
try {
    (New-Object Net.Sockets.TcpClient("localhost", 1935)).Close()
} catch {
    Write-Host "[start-camera] ERROR: nothing listening on localhost:1935."
    Write-Host "[start-camera] Start the server first: docker compose up -d  (or .\mediamtx.exe mediamtx.yml)"
    exit 1
}

# --- Push loop ----------------------------------------------------------------
# Retry loop: ffmpeg exits when the camera is unplugged (or grabbed by another
# app); keep relaunching so the stream recovers as soon as the device is back.
while ($true) {
    ffmpeg -f dshow -vcodec mjpeg -video_size "${Width}x${Height}" -framerate $Fps `
        -i "video=$CameraName" `
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p `
        -b:v 3000k -g $Fps `
        -f flv rtmp://localhost:1935/cam
    Write-Host "[start-camera] ffmpeg exited (camera unplugged?). Retrying in 3s... Ctrl+C to stop."
    Start-Sleep -Seconds 3
}
