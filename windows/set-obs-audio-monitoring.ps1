<#
  set-obs-audio-monitoring.ps1
  Sets the OBS audio monitoring device (profile) and the monitoring mode of
  chosen sources (scene collection).

  Dry run by default: prints current vs planned settings and changes nothing.
  Pass -Apply to write. OBS must be closed when applying, otherwise OBS
  overwrites the files on exit.

  Usage (on the OBS box):
    powershell -ExecutionPolicy Bypass -File .\set-obs-audio-monitoring.ps1
    powershell -ExecutionPolicy Bypass -File .\set-obs-audio-monitoring.ps1 -Apply

  Rollback: every -Apply copies both files to <file>.pre-monitoring first:
    Copy-Item <file>.pre-monitoring <file> -Force
#>
param(
    # OBS sources to monitor. "emeet-audio" = PIXY mic (EMEET Virtual Audio).
    [string[]]$Sources         = @("emeet-audio"),
    [ValidateSet("Off", "MonitorOnly", "MonitorAndOutput")]
    [string]  $Mode            = "MonitorOnly",
    # Output to monitor on; matched against active Windows playback devices.
    [string]  $MonitorDevice   = "Altavoces (Realtek(R) Audio)",
    [string]  $ObsProfile      = "Spingpong",
    [switch]  $Apply
)

$ErrorActionPreference = "Stop"
$obsDir   = "$env:APPDATA\obs-studio"
$iniPath  = "$obsDir\basic\profiles\$ObsProfile\basic.ini"
$jsonPath = (Get-ChildItem "$obsDir\basic\scenes\*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$utf8     = New-Object Text.UTF8Encoding($false)   # UTF-8 without BOM, what OBS writes
$modeNum  = @{ Off = 0; MonitorOnly = 1; MonitorAndOutput = 2 }[$Mode]
$modeName = @{ 0 = "Off"; 1 = "MonitorOnly"; 2 = "MonitorAndOutput" }

if ($Apply -and (Get-Process -Name obs64 -ErrorAction SilentlyContinue)) {
    Write-Error "OBS is running. Close it first, or it will overwrite these changes on exit."
}

# --- Active playback devices: friendly name -> OBS/WASAPI device id ----------
$mm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio"
$render = @{}
Get-ChildItem "$mm\Render" | Where-Object { (Get-ItemProperty $_.PSPath).DeviceState -eq 1 } | ForEach-Object {
    $p = Get-ItemProperty "$($_.PSPath)\Properties"
    $name = "{0} ({1})" -f $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2', $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    $render[$name] = "{0.0.0.00000000}." + $_.PSChildName
}
$activeIds = @($render.Values) + @(Get-ChildItem "$mm\Capture" |
    Where-Object { (Get-ItemProperty $_.PSPath).DeviceState -eq 1 } |
    ForEach-Object { "{0.0.1.00000000}." + $_.PSChildName })

if (-not $render.ContainsKey($MonitorDevice)) {
    Write-Host "Playback device '$MonitorDevice' not found. Active playback devices:"
    $render.Keys | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
$deviceId = $render[$MonitorDevice]

# --- Profile: monitoring device ---------------------------------------------
$ini = [IO.File]::ReadAllText($iniPath, $utf8)
$curName = if ($ini -match '(?m)^MonitoringDeviceName=(.*)$') { $Matches[1].Trim() } else { "(unset)" }
Write-Host "Profile '$ObsProfile' monitoring device: '$curName'  ->  '$MonitorDevice'"

$newIni = $ini
foreach ($kv in @(@("MonitoringDeviceName", $MonitorDevice), @("MonitoringDeviceId", $deviceId))) {
    $line = "$($kv[0])=$($kv[1])"
    if ($newIni -match "(?m)^$($kv[0])=.*$") {
        $newIni = $newIni -replace "(?m)^$($kv[0])=[^\r\n]*", $line
    } else {
        $newIni = $newIni -replace '(?m)^\[Audio\]\r?$', "`$0`r`n$line"
    }
}

# --- Scene collection: per-source monitoring mode ---------------------------
$scene = [IO.File]::ReadAllText($jsonPath, $utf8) | ConvertFrom-Json
Write-Host "Scene collection: $jsonPath"
foreach ($name in $Sources) {
    $src = $scene.sources | Where-Object { $_.name -eq $name }
    if (-not $src) { Write-Error "Source '$name' not found in the scene collection." }
    Write-Host ("  {0}: {1}  ->  {2}" -f $name, $modeName[[int]$src.monitoring_type], $Mode)
    $src.monitoring_type = $modeNum
}

# Report (do not fix) audio sources pointing at devices that no longer exist.
$scene.sources | Where-Object { $_.id -like "wasapi*" -and $_.settings.device_id -and $_.settings.device_id -ne "default" } |
    Where-Object { $activeIds -notcontains $_.settings.device_id } |
    ForEach-Object { Write-Warning "Source '$($_.name)' uses a missing device ($($_.settings.device_id)); it captures nothing." }

if (-not $Apply) {
    Write-Host "`nDry run: nothing written. Re-run with -Apply to save."
    exit 0
}

# --- Write (backup first) ----------------------------------------------------
Copy-Item $iniPath  "$iniPath.pre-monitoring"  -Force
Copy-Item $jsonPath "$jsonPath.pre-monitoring" -Force
[IO.File]::WriteAllText($iniPath, $newIni, $utf8)
[IO.File]::WriteAllText($jsonPath, ($scene | ConvertTo-Json -Depth 100), $utf8)
Write-Host "`nSaved. Backups: *.pre-monitoring next to each file. Start OBS to use the new settings."
