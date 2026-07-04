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

### Running without Docker

MediaMTX ships as a single static `.exe`, so Docker is optional on Windows:

1. Put `mediamtx.exe` in the `windows/` folder (next to `mediamtx.yml`).
   ⚠️ Extract **only the exe** — the release zip ships its own `mediamtx.yml`,
   which must not overwrite this repo's. From the `windows/` folder:

   ```powershell
   $asset = (Invoke-RestMethod https://api.github.com/repos/bluenviron/mediamtx/releases/latest).assets |
       Where-Object name -like "*windows_amd64.zip" | Select-Object -First 1
   Invoke-WebRequest $asset.browser_download_url -OutFile mediamtx.zip
   Expand-Archive mediamtx.zip -DestinationPath mediamtx-tmp
   Move-Item mediamtx-tmp\mediamtx.exe .
   Remove-Item mediamtx-tmp, mediamtx.zip -Recurse
   ```
2. Start the server with the same config the container uses:

   ```powershell
   cd windows
   .\mediamtx.exe mediamtx.yml   # instead of docker compose up -d
   .\start-camera.ps1            # unchanged (separate window)
   ```

Everything else is identical: same `rtmp://<host>:1935/cam` and
`rtsp://<host>:8554/cam` URLs, same camera identification steps below, same
reconnection behavior. To run it in the background, install it as a service
with e.g. [NSSM](https://nssm.cc) or a Scheduled Task set to run at logon.

> If the camera is plugged into the **same PC that runs OBS**, you don't need
> a server at all — add it directly in OBS as a *Video Capture Device* source.
> This setup is for consuming the camera from a different machine.

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

### Unattended startup (survive reboots)

For a dedicated streaming PC that must come back streaming after a reboot or
power cut, two scripts in `windows/`:

- **`start-all.ps1`** — starts everything in order: the server (native
  `mediamtx.exe` if present, else `docker compose up -d`), waits for port
  1935 (up to 3 min, Docker Desktop is slow after boot), launches
  `start-camera.ps1` minimized, then launches OBS. Idempotent — safe to
  re-run; it skips whatever is already running. Edit `$ObsExe` if OBS is
  installed somewhere non-default; add `--startstreaming` or
  `--startvirtualcam` to `$ObsArgs` to go live automatically.
- **`setup-autologin.ps1`** — one-time setup, run from an **elevated**
  PowerShell: enables Windows auto-login for the current user via
  [Sysinternals Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon)
  (the password is stored encrypted as an LSA secret, not in plain text) and
  registers a scheduled task that runs `start-all.ps1` at logon.
  `Autologon64.exe` is downloaded automatically from live.sysinternals.com if
  it isn't already next to the script or on PATH.

  To undo later: run `Autologon64.exe` and click *Disable*, then
  `Unregister-ScheduledTask -TaskName obs-camera-usb-startup`.

If using Docker: enable *"Start Docker Desktop when you sign in"* in Docker
Desktop settings — the compose file's `restart: unless-stopped` then brings
the server up on its own.

Already configured auto-login yourself (Autologon GUI or otherwise)? Run
`setup-autologin.ps1` anyway and answer **n** to the auto-login question — it
still registers the startup task, which is the part `start-all.ps1` needs.

### Two-machine setup (camera box + OBS PC)

One PC handles the camera and serves the stream (publisher); a different PC
runs OBS (subscriber). Each box gets its own startup script, registered at
logon by the same `setup-autologin.ps1`.

**Camera box** (the PC with the USB camera plugged in) — runs `start-all.ps1`:

1. Set `$StartObs = $false` at the top of `start-all.ps1` — no OBS here.
2. Register it at logon (answer "n" to auto-login if already configured):

   ```powershell
   # elevated PowerShell, in windows\
   powershell -ExecutionPolicy Bypass -File .\setup-autologin.ps1
   ```

3. Open the firewall for the stream ports (elevated PowerShell, one time):

   ```powershell
   New-NetFirewallRule -DisplayName "Camera RTSP/RTMP" -Direction Inbound `
       -Protocol TCP -LocalPort 8554,1935 -Action Allow
   ```

4. Note its IP: `ipconfig` → IPv4 address of the active adapter (give it a
   DHCP reservation in your router so it never changes).

**OBS PC** — runs `start-obs.ps1`, which waits until the camera box is
reachable and then launches OBS:

1. Set `$CameraBoxIp` at the top of `start-obs.ps1` to the camera box's IP.
2. In OBS, add the Media Source once: input
   `rtsp://<camera-box-ip>:8554/cam`, *Local File* unchecked, *Network
   Buffering* 0 MB, *Restart playback when source becomes active* checked.
3. Register it at logon:

   ```powershell
   # elevated PowerShell, in windows\
   powershell -ExecutionPolicy Bypass -File .\setup-autologin.ps1 -StartupScript start-obs.ps1
   ```

Reachability check if something doesn't connect:
`Test-NetConnection <camera-box-ip> -Port 8554`.

## Troubleshooting

- **Windows: "running scripts is disabled on this system"** (`la ejecución de
  scripts está deshabilitada`): PowerShell's execution policy blocks the
  script. Run it as
  `powershell -ExecutionPolicy Bypass -File .\start-camera.ps1`, or fix it
  once with `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` followed by
  `Unblock-File .\start-camera.ps1` (needed because files extracted from a
  downloaded zip carry the Mark-of-the-Web).
- **Black video but stream connects**: wrong device selected — usually the
  built-in laptop webcam (with privacy shutter closed) instead of the USB one.
- **OBS shows nothing after restart**: right-click the Media Source →
  Properties → OK to force a reconnect.
- **`Device or resource busy` / `Could not run graph`**: another app (or a
  previous ffmpeg) holds the camera. A camera can only be captured by one
  process at a time.
- **Stream stutters**: requested mode not actually supported at that
  framerate — re-check the supported-modes list and match exactly.
