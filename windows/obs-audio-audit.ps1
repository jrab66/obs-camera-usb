# Read-only audit of the OBS PC's audio setup. Changes nothing.
# Shows: logon session + OBS / EMEET Studio / RustDesk processes, active Windows
# audio endpoints, the OBS profile audio settings (monitoring device, sample
# rate), every audio/camera source with volume, mute, device and scenes, and
# the device each source last initialized in the current OBS log.
# Run on the OBS PC: powershell -ExecutionPolicy Bypass -File .\obs-audio-audit.ps1
$ProgressPreference = 'SilentlyContinue'
"=== session / processes ==="
query user 2>&1 | Out-String
Get-Process | Where-Object { $_.Name -match '^obs64$|EMEET|RustDesk$|mediamtx|ffmpeg' } |
  ForEach-Object { "{0} session={1} started={2}" -f $_.Name, $_.SessionId, $_.StartTime }

"=== active audio endpoints ==="
$mm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio"
$names = @{}
foreach ($kind in 'Render', 'Capture') {
  $prefix = if ($kind -eq 'Render') { '{0.0.0.00000000}.' } else { '{0.0.1.00000000}.' }
  Get-ChildItem "$mm\$kind" | ForEach-Object {
    $st = (Get-ItemProperty $_.PSPath).DeviceState
    $p = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
    $n = "{0} ({1})" -f $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2', $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    $names[$prefix + $_.PSChildName] = "$n [state=$st]"
    if ($st -eq 1) { "{0,-7} {1}" -f $kind, $n }
  }
}

"=== OBS profile audio ==="
$obs = "$env:APPDATA\obs-studio"
$prof = (Select-String -Path "$obs\global.ini", "$obs\user.ini" -Pattern '^ProfileDir=' -ErrorAction SilentlyContinue | Select-Object -First 1).Line
"active profile: $prof"
Get-ChildItem "$obs\basic\profiles\*\basic.ini" | ForEach-Object {
  "--- $($_.Directory.Name)"
  Select-String -Path $_.FullName -Pattern '^(MonitoringDeviceName|MonitoringDeviceId|SampleRate|ChannelSetup)=' | ForEach-Object { "  " + $_.Line }
}

"=== OBS audio sources (scene collection) ==="
$f = Get-ChildItem "$obs\basic\scenes\*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
"collection: $($f.Name) (saved $($f.LastWriteTime))"
$j = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
$mon = @{ 0 = 'off'; 1 = 'monitor-only'; 2 = 'monitor+output' }
$all = @($j.sources)
foreach ($k in $j.PSObject.Properties.Name) { if ($k -match 'AudioDevice') { $all += $j.$k } }
$inScenes = @{}
$j.sources | Where-Object id -eq 'scene' | ForEach-Object { $sc = $_.name; $_.settings.items | ForEach-Object { $inScenes[$_.name] = @($inScenes[$_.name]) + ("{0}{1}" -f $sc, $(if (-not $_.visible) { '(hidden)' })) } }
$all | Where-Object { $_.id -like 'wasapi*' -or $_.id -eq 'dshow_input' -or $_.id -eq 'ffmpeg_source' -or $_.id -eq 'browser_source' } | ForEach-Object {
  $dev = $_.settings.device_id
  $devName = if (-not $dev) { 'default' } elseif ($names.ContainsKey($dev)) { $names[$dev] } else { $dev }
  "{0,-28} {1,-22} mon={2,-14} vol={3,-5} muted={4,-5} dev={5} scenes={6}" -f $_.name, $_.id, $mon[[int]$_.monitoring_type], ([math]::Round([double]$_.volume, 2)), $_.muted, $devName, (($inScenes[$_.name] | Where-Object { $_ }) -join ',')
}

"=== current OBS log: latest device state per source ==="
$l = Get-ChildItem "$obs\logs\*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
"log: $($l.Name) (last write $($l.LastWriteTime))"
$last = @{}
Select-String -Path $l.FullName -Pattern "WASAPI: Device '(.*)' .*initialized \(source: (.*)\)|Device '(.*)' invalidated.*\(source: (.*)\)|failed to start \(source: (.*)\)|Audio monitoring device" | ForEach-Object {
  $line = $_.Line
  if ($line -match "initialized \(source: (.*)\)") { $last[$Matches[1]] = $line }
  elseif ($line -match "failed to start \(source: (.*)\)") { $last[$Matches[1]] = $line }
}
$last.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value }
Select-String -Path $l.FullName -Pattern 'Audio monitoring device|monitoring device' | Select-Object -Last 3 | ForEach-Object { $_.Line }
