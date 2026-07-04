# Push a USB camera into the MediaMTX container over RTMP.
# Run AFTER `docker compose up -d`. Requires ffmpeg on PATH (winget install ffmpeg).
#
# Set this to your camera's exact DirectShow name — see README.md "Identify your USB camera".
$CameraName = "USB Video Device"

# Match these to a mode your camera supports (README: "List supported modes").
$Width = 1280
$Height = 720
$Fps = 30

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
