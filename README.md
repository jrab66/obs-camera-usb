# usb-camera-rtmp

Expose a USB camera as an RTMP/RTSP IP camera for OBS, using MediaMTX + ffmpeg.

| Consume in OBS | URL |
|---|---|
| RTMP | `rtmp://<host>:1935/cam` |
| RTSP (lower latency, preferred) | `rtsp://<host>:8554/cam` |

OBS: **Sources → + → Media Source**, uncheck *Local File*, paste the URL,
set *Network Buffering* to 0 MB, enable *Use hardware decoding*.

## Linux

Everything runs in one container: MediaMTX plus an ffmpeg sidecar
(`runOnInit`) that captures the camera device.

```bash
docker compose up -d
```

### Identify your USB camera

```bash
# List all video devices grouped by physical camera
v4l2-ctl --list-devices
```

Example output:

```
UVC Camera (18d1:100d): UVC Cam (usb-0000:00:14.0-4):
        /dev/video5          <- capture device (use this one)
        /dev/video6          <- metadata device (ignore)
```

Each physical camera exposes several `/dev/video*` nodes — the **first** one
listed is the capture device. Ignore entries like "OBS Virtual Camera"
(v4l2loopback) and built-in laptop webcams.

To confirm which node actually captures video:

```bash
v4l2-ctl -d /dev/video5 --list-formats-ext
```

A capture device lists pixel formats (MJPG/YUYV) with resolutions and
framerates; a metadata device errors or lists none. Prefer an **MJPG** mode —
raw YUYV saturates USB 2.0 bandwidth and caps the framerate.

Then set the device in `mediamtx.yml` (the `-i ...` in `runOnInit`) and match
`-video_size` / `-framerate` to a mode the camera listed. Use the **stable
by-id path**, not `/dev/videoN` — numbering changes across reboots/re-plugs:

```bash
ls -l /dev/v4l/by-id/
# usb-Android_100d_20080411-video-index0 -> ../../video5   <- use index0
```

### USB reconnection handling

Unplugging and replugging the camera is handled automatically by three pieces:

1. `mediamtx.yml` → `runOnInitRestart: yes` relaunches ffmpeg whenever it dies
   (which is what happens when the camera disappears), retrying until the
   device is back.
2. `docker-compose.yml` mounts `/dev` and grants the video4linux device class
   via `device_cgroup_rules: c 81:* rmw`, instead of a static `devices:`
   mapping — a static mapping binds the node at container start and goes
   stale after a replug.
3. The ffmpeg input uses the `/dev/v4l/by-id/` path, which stays the same even
   if the kernel re-enumerates the camera to a different `/dev/videoN`.

Expect the stream to be back ~5–10 s after the camera reappears; OBS Media
Sources reconnect on their own (enable *"Restart playback when source becomes
active"*).

## Windows (`windows/` folder)

Docker Desktop (WSL2) cannot pass USB devices into containers, so the split is:

- **Container**: MediaMTX server only (`windows/docker-compose.yml`)
- **Host**: ffmpeg captures the camera via DirectShow and pushes RTMP to it
  (`windows/start-camera.ps1`)

```powershell
cd windows
docker compose up -d          # start the RTMP/RTSP server
.\start-camera.ps1            # start pushing the camera (keep window open)
```

Requires ffmpeg on the host: `winget install ffmpeg` (or `choco install ffmpeg`).

### Identify your USB camera

List all DirectShow video devices:

```powershell
ffmpeg -hide_banner -list_devices true -f dshow -i dummy
```

Example output:

```
[dshow] "Integrated Camera" (video)
[dshow] "USB Video Device" (video)      <- your USB camera
[dshow] "OBS Virtual Camera" (video)
```

Not sure which is which? Unplug the camera, run the command again, and see
which entry disappeared. Or check **Device Manager → Cameras**, or:

```powershell
Get-PnpDevice -Class Camera,Image -Status OK | Format-Table FriendlyName, InstanceId
```

(USB cameras have an `InstanceId` starting with `USB\`.)

### List supported modes

```powershell
ffmpeg -hide_banner -f dshow -list_options true -i video="USB Video Device"
```

This prints every resolution/framerate/pixel-format combination. Prefer an
**mjpeg** (`vcodec=mjpeg`) mode.

Copy the exact device name into `$CameraName` in `start-camera.ps1`, and set
`$Width` / `$Height` / `$Fps` to a listed mode. If two cameras share the same
name, disambiguate with the alternative name shown by `-list_devices`
(`video=@device_pnp_\\?\usb#...`).

### USB reconnection handling

`start-camera.ps1` runs ffmpeg in a retry loop: when the camera is unplugged
ffmpeg exits, and the script relaunches it every 3 s until the device is back.
DirectShow addresses the camera by name, so a replug needs no reconfiguration.
Stop the loop with Ctrl+C.

## Troubleshooting

- **Black video but stream connects**: wrong device selected — usually the
  built-in laptop webcam (with privacy shutter closed) instead of the USB one.
- **OBS shows nothing after restart**: right-click the Media Source →
  Properties → OK to force a reconnect.
- **`Device or resource busy` / `Could not run graph`**: another app (or a
  previous ffmpeg) holds the camera. A camera can only be captured by one
  process at a time.
- **Stream stutters**: requested mode not actually supported at that
  framerate — re-check the supported-modes list and match exactly.
