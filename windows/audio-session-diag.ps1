# Read-only diagnosis for "OBS audio only works while RDP is connected".
# Shows: machine / hypervisor, logon sessions (console vs rdp-tcp), which
# session OBS / EMEET Studio run in, audio services, every audio endpoint with
# its state (1 active, 2 disabled, 4 not present, 8 unplugged), audio PnP
# devices, RDP audio policy and recent audio-related system events.
# Typical finding: OBS started inside an RDP session only sees "Audio remoto";
# run OBS in the console session (auto-login, RustDesk) instead.
# Run on the OBS PC: powershell -ExecutionPolicy Bypass -File .\audio-session-diag.ps1
$ProgressPreference = 'SilentlyContinue'
"--- machine ---"
$cs = Get-CimInstance Win32_ComputerSystem; "{0} / {1} / HypervisorPresent={2}" -f $cs.Manufacturer, $cs.Model, $cs.HypervisorPresent
"--- sessions ---"
query user 2>&1 | Out-String
"--- processes per session (obs, emeet, rdp) ---"
Get-Process | Where-Object { $_.Name -match 'obs|emeet|rdpclip|mstsc|rustdesk|audiodg' } | ForEach-Object { "{0} session={1}" -f $_.Name, $_.SessionId }
"--- audio services ---"
Get-Service Audiosrv, AudioEndpointBuilder | ForEach-Object { "{0} {1} {2}" -f $_.Name, $_.Status, $_.StartType }
"--- all audio endpoints (1=active 2=disabled 4=notpresent 8=unplugged) ---"
$mm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio"
foreach ($kind in 'Render','Capture') {
  Get-ChildItem "$mm\$kind" | ForEach-Object {
    $p = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
    "{0} | state={1} | {2} ({3}) | {4}" -f $kind, (Get-ItemProperty $_.PSPath).DeviceState, $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2', $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6', $_.PSChildName
  }
}
"--- sound PnP devices ---"
Get-PnpDevice -Class MEDIA, AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { "{0} | {1} | present={2}" -f $_.FriendlyName, $_.Status, $_.Present }
"--- RDP audio policy ---"
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue | Select-Object fDisableCam, fDisableAudioCapture, fAllowUnlistedRemotePrograms | Format-List | Out-String
"--- recent audio-related system events ---"
Get-WinEvent -LogName System -MaxEvents 3000 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Audio|Realtek|AudioSrv' -or $_.Message -match 'Audio' } | Select-Object -First 10 | ForEach-Object { "{0} {1} {2}: {3}" -f $_.TimeCreated, $_.ProviderName, $_.Id, ($_.Message -split "`n")[0] }
