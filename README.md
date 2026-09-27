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

- **`watch-emeet-obs.ps1`** / **`install-watcher.ps1`** — watchdog for an
  EMEET PIXY Wireless fed through EMEET Studio into OBS; see
  [EMEET PIXY watcher](#emeet-pixy-watcher-obs-pc) below.

If using Docker: enable *"Start Docker Desktop when you sign in"* in Docker
Desktop settings — the compose file's `restart: unless-stopped` then brings
the server up on its own.

Already configured auto-login yourself (Autologon GUI or otherwise)? Run
`setup-autologin.ps1` anyway and answer **n** to the auto-login question — it
still registers the startup task, which is the part `start-all.ps1` needs.

### EMEET PIXY watcher (OBS PC)

For an OBS PC whose camera is an **EMEET PIXY Wireless** (Wi-Fi, on the LAN)
brought in by **EMEET Studio**: Studio receives the PIXY and exposes it as
the *EMEET STUDIO Virtual Camera* (video) and *EMEET Virtual Audio* (mic),
which OBS captures (source `emeet` + an audio input capture).

```
PIXY Wireless --Wi-Fi--> EMEET Studio --virtual camera / virtual audio--> OBS --> stream
```

The weak link is EMEET Studio 2.0.3: it **always starts with its virtual
camera off** (the switch is not saved), and it may need a restart to find the
PIXY again after the camera is switched back on. Until the virtual camera is
enabled, OBS shows black and gets no PIXY audio.

`watch-emeet-obs.ps1` runs every 5 minutes (scheduled task) and keeps the
chain up. Each run:

1. **EMEET Studio running?** If not, starts it and enables its virtual camera.
2. **OBS running?** If not, starts it (`--disable-shutdown-check --startvirtualcam`).
3. **PIXY on the network?** HTTP `200` from its built-in web server
   (`http://<CameraIp>:8000/`), falling back to ping. Note: a PIXY switched
   off with its button stays on Wi-Fi, so "online" means reachable, not
   streaming.
4. **Studio virtual camera on?** Read from Studio's own log (below); if off,
   enables it through the UI (below).
5. **Live picture in OBS?** Two snapshots of the `emeet` source through
   obs-websocket, 3 s apart. Dark = *BLACK*, byte-identical = *FROZEN* (live
   video always differs by sensor noise). If bad: restart the OBS source; still
   bad and the PIXY is online: restart EMEET Studio (which re-enables its
   virtual camera) and check again. PIXY offline: log only.
6. **OBS Virtual Camera on?** If not, starts it.
7. **PIXY mic:** logs the Windows *EMEET Virtual Audio* endpoint state and
   whether the OBS mic source is muted (never changes it).

`-CheckOnly` reports all of the above without starting, restarting or
clicking anything.

#### How the EMEET Studio automation works

- **Virtual camera state** comes from Studio's log,
  `%LOCALAPPDATA%\EMEET STUDIO\Logs\av.log`: each launch writes
  `virtual camera is registered` (= off), enabling writes
  `openVirtualCamera 2` (= on), disabling writes `closeVirtualCamera` (= off).
  The last of those lines wins.
- **Enabling it** uses Windows UI Automation: Studio (Qt/QML) exposes its
  controls with stable ids. The *V-Cam* tab (`tab_video_output_item_vCam`)
  ignores UI Automation, so the script brings Studio to the front and clicks
  the tab's centre with the mouse (cursor put back afterwards), then invokes
  **Enable Virtual Camera** (`btn_vcam_toggle`) through UI Automation. The
  button is a toggle, so it is only pressed when the log says *off*.
- UI Automation only works **inside the logged-on console session**, which is
  why the scheduled task runs as the interactive user.

#### Install / update

On the OBS PC, copy the `windows\` scripts next to each other, then from an
**elevated** PowerShell in `windows\`:

```powershell
# dry run: reports, changes nothing
powershell -ExecutionPolicy Bypass -File .\watch-emeet-obs.ps1 -CheckOnly

# register the task: every 5 min from now, plus once 3 min after each logon
powershell -ExecutionPolicy Bypass -File .\install-watcher.ps1
Start-ScheduledTask -TaskName obs-camera-usb-watcher

# follow the log
Get-Content $env:LOCALAPPDATA\obs-camera-usb\watcher.log -Tail 20 -Wait
```

Updating the script later: replace `watch-emeet-obs.ps1`; the task picks it up
on its next run. Remove everything:
`Unregister-ScheduledTask -TaskName obs-camera-usb-watcher`.

#### Settings (top of `watch-emeet-obs.ps1`)

| Setting | Default | Meaning |
|---|---|---|
| `$CameraSource` | `emeet` | OBS source showing the PIXY |
| `$MicSource` / `$MicEndpointName` | `emeet-audio` / `EMEET Virtual Audio` | OBS mic source / Windows endpoint to report |
| `$CameraIp` | `192.168.100.20` | PIXY on the LAN (give it a DHCP reservation) |
| `$BlackThreshold` | `8` | average snapshot brightness (0-255) below this = black |
| `$RestartEmeetStudio` | `$true` | allow restarting Studio when the picture stays bad |
| `$StudioRestartCooldownMin` | `4` | minimum minutes between Studio restarts (4 = any run) |
| `$StudioStartWaitSec` | `20` | wait after starting Studio before enabling its virtual camera (then retries up to 60 s) |
| `$EnsureObsVirtualCam` | `$true` | keep the OBS Virtual Camera on |

#### What a healthy log looks like

```
[watcher] EMEET Studio: running
[watcher] OBS: running
[watcher] PIXY 192.168.100.20: online
[watcher] EMEET Studio virtual camera: on
[watcher] camera 'emeet': picture OK (brightness 101.9)
[watcher] OBS virtual camera: on
[watcher] mic: Windows 'EMEET Virtual Audio' active; OBS 'emeet-audio' unmuted
```

Recovery after Studio was closed (verified 2026-09-27, ~35 s to a live picture):

```
[watcher] EMEET Studio: not running - starting it
[watcher] EMEET Studio virtual camera: was off - enabled
[watcher] camera 'emeet': picture OK (brightness 101.9)
```

#### Gotchas

- **Don't manage the OBS PC over RDP; use RustDesk (or the physical screen).**
  An RDP logon leaves a *RemoteInteractive* session: Windows gives it RDP's
  audio devices ("Audio remoto") instead of the real ones, so OBS mics fail
  (`GetDefaultAudioEndpoint: 80070490`), and Task Scheduler refuses to run
  logged-on-user tasks in it (`0x800710E0`). Fix: reboot so auto-login
  creates a fresh console session.
- **PIXY switched off = still on Wi-Fi.** While it is off, the watcher sees
  it online with a black picture and restarts Studio every run; harmless,
  and it means the picture comes back within one run of switching it on.
- **Studio's window may pop to the front** when the watcher enables its
  virtual camera (the tab click needs it). Expected on an unattended box.

### OBS audio tools (OBS PC)

Three standalone scripts in `windows\` for checking and setting OBS audio on
the OBS PC. **Manual, on-demand tools: nothing runs them automatically** —
they are not called by `start-all.ps1`, `start-obs.ps1`, the watcher, or any
scheduled task. Keep them for troubleshooting; run them by hand in PowerShell
on that PC (`powershell -ExecutionPolicy Bypass -File .\<script>`).

- **`obs-audio-audit.ps1`** (read-only) — snapshot of the audio setup: logon
  session and OBS / EMEET Studio / RustDesk processes, active Windows audio
  endpoints, the OBS profile's monitoring device / sample rate / channels,
  every audio and camera source (volume, mute, device, which scenes use it)
  and the device each source last opened according to the current OBS log.
  Run it before and after a change to compare.
- **`set-obs-audio-monitoring.ps1`** — sets the OBS *monitoring* output
  (`-MonitorDevice`, matched against active Windows playback devices) and the
  monitoring mode of chosen sources (`-Sources`, `-Mode Off | MonitorOnly |
  MonitorAndOutput`) for profile `-ObsProfile`. **Dry run by default**: it
  prints current vs planned values and warns about sources pointing at audio
  devices that no longer exist. `-Apply` writes, only with OBS closed, after
  copying both files to `*.pre-monitoring` (restore = copy them back).
  Defaults: source `emeet-audio` (PIXY mic), `MonitorOnly`, speakers
  `Altavoces (Realtek(R) Audio)`, profile `Spingpong`.
- **`audio-session-diag.ps1`** (read-only) — for "OBS audio only works while
  RDP is connected": machine, logon sessions (console vs `rdp-tcp`), which
  session OBS / EMEET Studio run in, audio services, every audio endpoint and
  its state, audio devices, RDP audio policy, recent audio events. Typical
  finding: OBS was started inside an RDP session and only sees *Audio remoto*
  (see the RDP gotcha under [EMEET PIXY watcher](#emeet-pixy-watcher-obs-pc)).

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
