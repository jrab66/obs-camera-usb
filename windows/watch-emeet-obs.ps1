# Watchdog for the EMEET PIXY -> EMEET Studio -> OBS chain. Meant to run every
# 5 minutes from a scheduled task (see install-watcher.ps1); safe to run by hand.
#
# Each run:
#   1. EMEET Studio running? If not, start it (it feeds the PIXY into
#      "EMEET STUDIO Virtual Camera" + "EMEET Virtual Audio").
#   2. OBS running? If not, start it with the virtual camera on.
#   3. Is the PIXY itself on the network ($CameraIp: HTTP on :8000, else ping)?
#      Via obs-websocket: does the $CameraSource source show a live picture?
#      Two snapshots 3 s apart: black (dark) or frozen (byte-identical) = bad.
#      Fix in steps: restart the OBS source; still bad and the PIXY is online
#      = restart EMEET Studio (at most once per $StudioRestartCooldownMin min)
#      and re-check. PIXY offline = only log it (power / Wi-Fi problem).
#   4. OBS Virtual Camera on? If not, start it.
#   5. Log (never change) the PIXY mic: Windows endpoint state + OBS mute.
#
# -CheckOnly: report only, change nothing (no starts, no source restart).
# Log: %LOCALAPPDATA%\obs-camera-usb\watcher.log

param(
    [switch]$CheckOnly
)

# OBS source names (from the working scene collection, 2026-09-27)
$CameraSource = "emeet"
$MicSource = "Captura de entrada audio"
$MicEndpointName = "EMEET Virtual Audio"

$ObsExe = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
$ObsArgs = @("--disable-shutdown-check", "--startvirtualcam")
$EmeetStudioExe = "C:\Program Files\EMEET STUDIO\bin\64bit\EMEET STUDIO.exe"
$EnsureObsVirtualCam = $true
# Average snapshot brightness (0-255) below this counts as "no picture".
$BlackThreshold = 8
# The PIXY Wireless on the LAN; port 8000 is its built-in web server.
$CameraIp = "192.168.100.20"
$CameraHealthUrl = "http://${CameraIp}:8000/"
# Runs are 5 min apart and the restart stamp is written ~20 s into a run, so
# 4 min lets every run restart EMEET Studio when needed.
$StudioRestartCooldownMin = 4
# EMEET Studio 2.0.3 comes back with its virtual camera OFF after a restart
# (not saved in its settings), so restarting it breaks the feed until someone
# clicks the switch. Keep this off until that can be automated.
$RestartEmeetStudio = $false

$logDir = Join-Path $env:LOCALAPPDATA "obs-camera-usb"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "watcher.log"
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    Move-Item $logFile "$logFile.old" -Force
}
function Log($msg) {
    $line = "{0} [watcher] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

# --- obs-websocket v5 client (PowerShell 5.1, no modules) -----------------------
$script:ws = $null
$script:reqId = 0

function Receive-ObsMessage {
    $buffer = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    do {
        $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buffer)
        $task = $script:ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $task.Wait(15000)) { throw "timeout waiting for obs-websocket" }
        $ms.Write($buffer, 0, $task.Result.Count)
    } while (-not $task.Result.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

function Send-ObsMessage($obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $seg = New-Object ArraySegment[byte] -ArgumentList @(, $bytes)
    $script:ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).Wait()
}

function Connect-Obs {
    $cfgPath = Join-Path $env:APPDATA "obs-studio\plugin_config\obs-websocket\config.json"
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $script:ws = New-Object Net.WebSockets.ClientWebSocket
    $script:ws.Options.AddSubProtocol("obswebsocket.json")
    $uri = [Uri]("ws://127.0.0.1:{0}" -f $cfg.server_port)
    if (-not $script:ws.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait(10000)) {
        throw "timeout connecting to $uri"
    }
    $hello = Receive-ObsMessage
    $identify = @{ rpcVersion = 1; eventSubscriptions = 0 }
    if ($hello.d.authentication) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $secret = [Convert]::ToBase64String($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($cfg.server_password + $hello.d.authentication.salt)))
        $identify.authentication = [Convert]::ToBase64String($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($secret + $hello.d.authentication.challenge)))
    }
    Send-ObsMessage @{ op = 1; d = $identify }
    $ident = Receive-ObsMessage
    if ($ident.op -ne 2) { throw "obs-websocket identify failed" }
}

function Invoke-Obs($type, $data = @{}) {
    $script:reqId++
    $id = "w$($script:reqId)"
    Send-ObsMessage @{ op = 6; d = @{ requestType = $type; requestId = $id; requestData = $data } }
    do { $msg = Receive-ObsMessage } while ($msg.op -ne 7 -or $msg.d.requestId -ne $id)
    if (-not $msg.d.requestStatus.result) {
        throw "$type failed: $($msg.d.requestStatus.comment)"
    }
    $msg.d.responseData
}

function Get-SourceBrightness($name, $b64 = $null) {
    if (-not $b64) {
        $shot = Invoke-Obs "GetSourceScreenshot" @{ sourceName = $name; imageFormat = "png"; imageWidth = 64 }
        $b64 = $shot.imageData -replace "^data:image/png;base64,", ""
    }
    Add-Type -AssemblyName System.Drawing
    $stream = New-Object IO.MemoryStream(, [Convert]::FromBase64String($b64))
    $bmp = New-Object Drawing.Bitmap($stream)
    $sum = 0
    for ($x = 0; $x -lt $bmp.Width; $x += 4) {
        for ($y = 0; $y -lt $bmp.Height; $y += 4) {
            $p = $bmp.GetPixel($x, $y)
            $sum += ($p.R + $p.G + $p.B) / 3
        }
    }
    $count = [math]::Ceiling($bmp.Width / 4) * [math]::Ceiling($bmp.Height / 4)
    $bmp.Dispose()
    [math]::Round($sum / $count, 1)
}

# Two snapshots 3 s apart. Live video always differs a little (sensor noise),
# so byte-identical frames mean the feed is frozen.
function Get-SourceState($name) {
    $a = (Invoke-Obs "GetSourceScreenshot" @{ sourceName = $name; imageFormat = "png"; imageWidth = 64 }).imageData
    Start-Sleep -Seconds 3
    $b = (Invoke-Obs "GetSourceScreenshot" @{ sourceName = $name; imageFormat = "png"; imageWidth = 64 }).imageData
    $level = Get-SourceBrightness $name ($b -replace "^data:image/png;base64,", "")
    $frozen = ($a -eq $b)
    $text = if ($level -lt $BlackThreshold) { "BLACK (brightness $level)" }
            elseif ($frozen) { "FROZEN (identical frames, brightness $level)" }
            else { "picture OK (brightness $level)" }
    [pscustomobject]@{
        Brightness = $level
        Frozen     = $frozen
        Ok         = ($level -ge $BlackThreshold -and -not $frozen)
        Text       = $text
    }
}

function Test-CameraOnline {
    try {
        $r = Invoke-WebRequest -Uri $CameraHealthUrl -UseBasicParsing -TimeoutSec 4
        return ($r.StatusCode -eq 200)
    } catch {
        return (Test-Connection -ComputerName $CameraIp -Count 1 -Quiet)
    }
}

function Restart-ObsSource($name) {
    Invoke-Obs "SetInputSettings" @{ inputName = $name; inputSettings = @{ active = $false } } | Out-Null
    Start-Sleep -Seconds 2
    Invoke-Obs "SetInputSettings" @{ inputName = $name; inputSettings = @{ active = $true } } | Out-Null
    Start-Sleep -Seconds 8
}

# --- 1. EMEET Studio ------------------------------------------------------------
if (Get-Process -Name "EMEET STUDIO" -ErrorAction SilentlyContinue) {
    Log "EMEET Studio: running"
} elseif ($CheckOnly) {
    Log "EMEET Studio: NOT running (check-only, not starting)"
} else {
    Log "EMEET Studio: not running - starting it"
    Start-Process -FilePath $EmeetStudioExe -WorkingDirectory (Split-Path $EmeetStudioExe) -WindowStyle Minimized
    Start-Sleep -Seconds 20
}

# --- 2. OBS ---------------------------------------------------------------------
if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
    Log "OBS: running"
} elseif ($CheckOnly) {
    Log "OBS: NOT running (check-only, not starting)"
    exit 1
} else {
    Log "OBS: not running - starting it"
    Start-Process -FilePath $ObsExe -ArgumentList $ObsArgs -WorkingDirectory (Split-Path $ObsExe)
    Start-Sleep -Seconds 30
}

try {
    Connect-Obs
} catch {
    Log "obs-websocket: cannot connect ($($_.Exception.Message)) - skipping OBS checks"
    exit 1
}

# --- 3. Camera: PIXY on the network, live picture in OBS ------------------------
$cameraOnline = Test-CameraOnline
Log ("PIXY {0}: {1}" -f $CameraIp, $(if ($cameraOnline) { "online" } else { "OFFLINE (no answer on :8000 or ping)" }))
try {
    $state = Get-SourceState $CameraSource
    if ($state.Ok) {
        Log "camera '$CameraSource': $($state.Text)"
    } elseif ($CheckOnly) {
        Log "camera '$CameraSource': $($state.Text) (check-only, not fixing)"
    } else {
        Log "camera '$CameraSource': $($state.Text) - restarting the OBS source"
        Restart-ObsSource $CameraSource
        $state = Get-SourceState $CameraSource
        if ($state.Ok) {
            Log "camera '$CameraSource': fixed by source restart - $($state.Text)"
        } elseif (-not $RestartEmeetStudio) {
            Log "camera '$CameraSource': still $($state.Text) - turn on the virtual camera in EMEET Studio (automatic Studio restart disabled)"
        } elseif (-not $cameraOnline) {
            Log "camera '$CameraSource': still $($state.Text); PIXY is offline - check its power / Wi-Fi (not restarting EMEET Studio)"
        } else {
            $stamp = Join-Path $logDir "studio-restart.txt"
            $last = [datetime]::MinValue
            if (Test-Path $stamp) { $last = [datetime](Get-Content $stamp -Raw).Trim() }
            if (((Get-Date) - $last).TotalMinutes -lt $StudioRestartCooldownMin) {
                Log "camera '$CameraSource': still $($state.Text); EMEET Studio was restarted at $last - waiting for the $StudioRestartCooldownMin min cooldown"
            } else {
                Log "camera '$CameraSource': still $($state.Text) with the PIXY online - restarting EMEET Studio"
                Set-Content -Path $stamp -Value (Get-Date -Format "o")
                Stop-Process -Name "EMEET STUDIO" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Start-Process -FilePath $EmeetStudioExe -WorkingDirectory (Split-Path $EmeetStudioExe) -WindowStyle Minimized
                Start-Sleep -Seconds 30
                Restart-ObsSource $CameraSource
                $state = Get-SourceState $CameraSource
                if ($state.Ok) {
                    Log "camera '$CameraSource': fixed by EMEET Studio restart - $($state.Text)"
                } else {
                    Log "camera '$CameraSource': still $($state.Text) after EMEET Studio restart - check the virtual camera switch in EMEET Studio"
                }
            }
        }
    }
} catch {
    Log "camera '$CameraSource': check failed ($($_.Exception.Message))"
}

# --- 4. OBS Virtual Camera ------------------------------------------------------
if ($EnsureObsVirtualCam) {
    try {
        $vc = Invoke-Obs "GetVirtualCamStatus"
        if ($vc.outputActive) {
            Log "OBS virtual camera: on"
        } elseif ($CheckOnly) {
            Log "OBS virtual camera: OFF (check-only, not starting)"
        } else {
            Invoke-Obs "StartVirtualCam" | Out-Null
            Log "OBS virtual camera: was off - started"
        }
    } catch {
        Log "OBS virtual camera: check failed ($($_.Exception.Message))"
    }
}

# --- 5. PIXY mic (report only) --------------------------------------------------
$mm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"
$micActive = $false
Get-ChildItem $mm | ForEach-Object {
    $p = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
    if ($p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' -like "*$MicEndpointName*" -or
        $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' -like "*$MicEndpointName*") {
        if ((Get-ItemProperty $_.PSPath).DeviceState -eq 1) { $micActive = $true }
    }
}
try {
    $mute = Invoke-Obs "GetInputMute" @{ inputName = $MicSource }
    Log ("mic: Windows '{0}' {1}; OBS '{2}' {3}" -f $MicEndpointName,
        $(if ($micActive) { "active" } else { "NOT ACTIVE" }), $MicSource,
        $(if ($mute.inputMuted) { "MUTED" } else { "unmuted" }))
} catch {
    Log "mic: OBS check failed ($($_.Exception.Message))"
}

$script:ws.Dispose()
