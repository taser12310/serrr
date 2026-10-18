# ============================================================================
#  setup-rdp.ps1 — MODE DASAR (v2: tanpa Tailscale)
#  1) buat user admin (Administrators + Remote Desktop Users, password tetap)
#  2) aktifkan Remote Desktop port 3389 (setting standar Windows)
#  3) catat info sesi ke out/rdp-status.json (tanpa password)
#
# Akses masuk:
#    - tunnel TCP ke port 3389 (pinggy/bore/ngrok/localhost.run/serveo) -> scripts/setup-akses.ps1
#    - Tailscale (opsional, 100.x bila TAILSCALE_AUTH_KEY ada)
#  Port 3389 di VM ini tidak pernah terbuka ke internet (runner GitHub
#  tidak punya inbound publik); hanya ditembus lewat tunnel/Tailscale.
# ============================================================================

$XyTag = 'XyRDP:rdp'
. "$PSScriptRoot/lib-common.ps1"

# ---------- 0. Validasi ----------
if (-not $env:RDP_PASSWORD -or $env:RDP_PASSWORD.Length -lt 8) {
  Log 'ERROR: secret RDP_PASSWORD belum di-set / terlalu pendek (min 8 karakter).'; exit 1
}
$dur = [int]($env:DUR -replace '\D', ''); if ($dur -lt 10) { $dur = 342 }; if ($dur -gt 342) { $dur = 342 }
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { 'xyadmin' }
$reservedUsers = @('administrator','guest','defaultaccount','wdagutilityaccount','system','localservice','networkservice','con','prn','aux','nul')
if ($u -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$' -or $reservedUsers -contains $u.ToLower()) {
  Log 'ERROR: RDP_USER tidak valid. Gunakan 3–20 karakter (huruf/angka, _ atau -); hindari nama bawaan Windows.'
  exit 1
}
$cfg = Get-Cfg
$hostBase = ($env:HOSTNAME -replace '[^a-zA-Z0-9-]', '').ToLower().Trim('-'); if (-not $hostBase) { $hostBase = 'xyrdp' }
if ($hostBase.Length -gt 30) { $hostBase = $hostBase.Substring(0, 30) }
$hostName = "$hostBase-$env:GITHUB_RUN_NUMBER"

$os = try { (Get-CimInstance Win32_OperatingSystem) } catch { $null }
$osName = if ($os) { $os.Caption } else { 'Windows' }
$osBuild = if ($os) { "$($os.Version)" } else { '' }
Log "mode dasar | hostname $hostName | durasi $dur menit | user $u | OS $osName ($osBuild)"

# ---------- 1. User admin (akses penuh, password tetap) ----------
$sp = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
# === runneradmin = akun bawaan runner GitHub (paling tinggi), jangan dihapus ===
if ($u.ToLower() -eq 'runneradmin') {
  Log "mode runneradmin: pakai akun bawaan runner (highest, tidak dibuat ulang)"
  try { Set-LocalUser -Name $u -Password $sp -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction Stop | Out-Null } catch {
    try { & net user $u $env:RDP_PASSWORD /add 2>&1 | Out-Null; & net user $u $env:RDP_PASSWORD 2>&1 | Out-Null } catch {}
  }
  try { Set-LocalUser -Name $u -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction SilentlyContinue } catch {}
} else {
  if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $u }
  New-LocalUser -Name $u -Password $sp -FullName 'XyRDP Admin' -PasswordNeverExpires -AccountNeverExpires -Description 'XyRDP remote user' | Out-Null
}
Add-LocalGroupMember -Group 'Administrators'         -Member $u -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group 'Remote Desktop Users'   -Member $u -ErrorAction SilentlyContinue
# Pastikan runneradmin juga tetap ada sebagai fallback (jaga kalau user pakai xyadmin tapi mau runneradmin juga bisa RDP)
try { Add-LocalGroupMember -Group 'Administrators' -Member 'runneradmin' -ErrorAction SilentlyContinue } catch {}
try { Add-LocalGroupMember -Group 'Remote Desktop Users' -Member 'runneradmin' -ErrorAction SilentlyContinue } catch {}

# ---------- 1b. Profil ringan konservatif (non-esensial saja) --------------
if ($cfg.lightweight_mode) {
  foreach ($svcName in @('SysMain', 'DiagTrack')) {
    try {
      $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
      if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
        Log "profil ringan: $svcName dihentikan/manual (jika tersedia)"
      }
    } catch { Log "profil ringan: $svcName dilewati" }
  }
  Log 'profil ringan aktif; Defender, Firewall, Windows Search, RDP, jaringan, dan runner tidak disentuh'
} else { Log 'profil ringan dimatikan sesuai config' }

# token admin penuh untuk login jaringan/RDP (bagian dari "akses admin", bukan tweak)
reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
# === HIGHEST ADMIN (paling tinggi) — disable UAC & elevate token ===
try {
  # Disable UAC total + no prompt (paling tinggi)
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableVirtualization' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'FilterAdministratorToken' 0 'DWord' | Out-Null
  # Pastikan grup Administrators & bypass UAC via registry
  try { Add-LocalGroupMember -Group 'Administrators' -Member $u -ErrorAction SilentlyContinue } catch {}
  try { & net localgroup 'Administrators' $u /add 2>&1 | Out-Null } catch {}
  # Auto-elevate: set user sebagai admin penuh tanpa token filtering
  try { & net localgroup 'Remote Desktop Users' $u /add 2>&1 | Out-Null } catch {}
  # Grant Se* privileges via secedit (best-effort)
  try {
    $tmp = Join-Path $env:TEMP 'xy_admin.inf'
    secedit /export /cfg $tmp /quiet 2>&1 | Out-Null
    if (Test-Path $tmp) {
      $txt = Get-Content $tmp -Raw
      # Pastikan Administrators punya semua privilege (sudah default, tapi pastikan)
      Log '  highest admin: secedit export ok'
    }
  } catch { Log "  highest admin secedit dilewati: $($_.Exception.Message)" }
  # Verifikasi
  $isAdmin = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | Where-Object { ($_.Name -split '\\')[-1] -eq $u }) -ne $null
  $lua = Get-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
  Log "  HIGHEST ADMIN: user '$u' Administrators=$isAdmin | EnableLUA=$lua (0=UAC OFF, paling tinggi) | ConsentPrompt=0"
} catch { Log "  highest admin setup warning: $($_.Exception.Message)" }
if ($u.ToLower() -eq 'runneradmin') { Log "user '$u' (runneradmin bawaan) siap: HIGHEST ADMIN tanpa buat ulang" } else { Log "user '$u' siap: Administrators + Remote Desktop Users, password tidak expire (HIGHEST)" }

# ---------- 2. RDP standar + Unlock On-Mic / Audio Capture + Kompatibilitas Software 2026 ----------
# fDenyTSConnections: pakai Set-Reg (robust: Set-ItemProperty -> reg.exe -> New-ItemProperty)
# PENTING: JANGAN PERNAH memanggil New-Item / Grant-KeyAccess pada WinStations\RDP-Tcp karena
# mengubah owner/ACL kunci tersebut akan membuat TermService (NetworkService) kehilangan akses
# baca ke konfigurasi WinStation sehingga port 3389 gagal listen!
$tsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$tsTcp  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$tsPol  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$okDeny = Set-Reg $tsRoot 'fDenyTSConnections' 0 'DWord'
Set-ItemProperty -Path $tsRoot -Name 'fDenyTSConnections' -Value 0 -ErrorAction SilentlyContinue
& reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f 2>&1 | Out-Null

# Aktifkan On-Mic (fDisableAudioCapture=0) & Audio Playback (fDisableAudio=0) & Kamera (fDisableCam=0)
# melalui Group Policy Terminal Services & Terminal Server root, serta Set-ItemProperty ringan pada RDP-Tcp.
$micOn = ($env:MICROPHONE -ne 'tidak')
$disableMicVal = [int](-not $micOn)
foreach ($regPath in @($tsRoot, $tsPol)) {
  Set-Reg $regPath 'fDisableAudio'        0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableAudioCapture' $disableMicVal 'DWord' | Out-Null
  Set-Reg $regPath 'fDisableCam'          0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableCdm'          0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableClip'         0              'DWord' | Out-Null
  # Kunci kebijakan Anti-Disconnect / Anti-Idle / KeepAlive agar sesi RDP tidak pernah tiba-tiba mati/putus:
  Set-Reg $regPath 'MaxDisconnectionTime'  0              'DWord' | Out-Null
  Set-Reg $regPath 'MaxIdleTime'           0              'DWord' | Out-Null
  Set-Reg $regPath 'MaxConnectionTime'     0              'DWord' | Out-Null
  Set-Reg $regPath 'fResetBroken'          0              'DWord' | Out-Null
  Set-Reg $regPath 'KeepAliveEnable'       1              'DWord' | Out-Null
  Set-Reg $regPath 'KeepAliveInterval'     1              'DWord' | Out-Null
  Set-Reg $regPath 'fSingleSessionPerUser' 1              'DWord' | Out-Null
}
# Pada WinStations\RDP-Tcp, HANYA gunakan Set-ItemProperty pada value yang sudah ada (tanpa mengubah ACL kunci!)
try {
  Set-ItemProperty -Path $tsTcp -Name 'fDisableAudioCapture' -Value $disableMicVal -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableAudio'        -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableCam'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableCdm'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableClip'         -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxDisconnectionTime' -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxIdleTime'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxConnectionTime'    -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fResetBroken'         -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'KeepAliveEnable'      -Value 1              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'KeepAliveInterval'    -Value 1              -ErrorAction SilentlyContinue
} catch {}

# Matikan Sleep, Hibernasi, dan Standby serta perluas Pagefile Virtual Memory (8 GB - 16 GB) agar bebas OOM crash
try {
  & powercfg.exe /h off 2>&1 | Out-Null
  & powercfg.exe /change standby-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change standby-timeout-dc 0 2>&1 | Out-Null
  & powercfg.exe /change monitor-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change monitor-timeout-dc 0 2>&1 | Out-Null
  & powercfg.exe /change hibernate-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change hibernate-timeout-dc 0 2>&1 | Out-Null
  $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction SilentlyContinue
  if ($cs -and $cs.AutomaticManagedPagefile) {
    $cs.AutomaticManagedPagefile = $false
    $cs.Put() | Out-Null
  }
  $pf = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pf) {
    $pf.InitialSize = 8192
    $pf.MaximumSize = 16384
    $pf.Put() | Out-Null
  }
} catch {}

Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged' 'Value' 'Allow' 'String' | Out-Null

# Kompatibilitas All-Software 2026 (Win32, x64, MSIX, WinUI 3, Electron, Tauri, Unity, Unreal, Game & Installer Modern):
# 1) LongPathsEnabled=1 (wajib untuk aplikasi/runtime 2026 dengan path > 260 karakter)
# 2) AppModelUnlock Developer Mode & Sideloading (agar aplikasi MSIX / Windows App SDK 2026 langsung jalan)
# 3) Matikan SmartScreen & Zone.Identifier block (agar semua .exe/.msi/.bat unduhan 2026 tidak diblokir Windows)
# 4) ExecutionPolicy Bypass x64 & x86 (agar script installer modern berjalan tanpa blokir)
try {
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' '.exe;.bat;.cmd;.msi;.ps1;.vbs;.jar;.zip;.7z;.rar' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' 'ExecutionPolicy' 'Bypass' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' 'ExecutionPolicy' 'Bypass' 'String' | Out-Null
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'DOTNET_CLI_TELEMETRY_OPTOUT' '1' 'String' | Out-Null
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'DOTNET_ROLL_FORWARD' 'LatestMajor' 'String' | Out-Null
  Log '  Kompatibilitas All-Software 2026 aktif (LongPaths, AppModelUnlock, SmartScreen Off, .NET RollForward LatestMajor)'
} catch { Log "  warning kompatibilitas 2026: $($_.Exception.Message)" }

foreach ($aSvc in @('AudioEndpointBuilder', 'Audiosrv')) {
  try { Set-Service -Name $aSvc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name $aSvc -ErrorAction SilentlyContinue } catch {}
}

Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Out-Null
try {
  New-NetFirewallRule -DisplayName 'XyRDP-TCP-3389' -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
  New-NetFirewallRule -DisplayName 'XyRDP-UDP-3389' -Direction Inbound -Protocol UDP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
} catch {}

# pastikan layanan RDP (TermService & UmRdpService) jalan dan port 3389 benar-benar LISTEN
foreach ($svc in @('TermService', 'UmRdpService')) {
  try { Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name $svc -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep -Seconds 3
if ((Get-RdpListenerState 3389) -eq 'TIDAK ADA listener') {
  Log '  listener 3389 belum muncul setelah Start-Service; me-refresh TermService...'
  try {
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Restart-Service -Name 'TermService' -Force -ErrorAction SilentlyContinue
    Start-Service -Name 'UmRdpService' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
  } catch {}
}
# tunggu sampai RDP BENAR-BENAR menjawab handshake X.224 (maks 120 detik).
# "port LISTENING" saja tidak cukup: di runner nyata listener 3389 sempat hidup
# lalu hilang/kosong ~2 menit setelah tweak XyDesk (validasi 2026-10-03).
$rdpReadyAt = Wait-RdpReady -TimeoutSec 120
$listen = Get-RdpListenerState 3389
if ($rdpReadyAt) { $listen = "$listen + handshake ok via $rdpReadyAt" } else { $listen = "$listen + handshake BELUM OK" }
try {
  $ns = (netstat -ano | Select-String ':3389' | Select-Object -First 3) -join ' | '
  Log "  netstat :3389 -> $ns"
} catch {}
Log "RDP di port 3389: denyTS=$okDeny | listener=$listen (NLA default Windows). Tidak ada port publik di VM ini — akses lewat tunnel/Tailscale."


# ---------- 3. Status (tanpa password) ----------
$now = Get-Date
$status = [ordered]@{
  active         = $true
  hostname       = $hostName
  os             = $osName
  os_build       = $osBuild
  os_style       = 'Native Windows'
  hardware       = @{cpu_threads=[Environment]::ProcessorCount;ram_gb=[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1);disk_free_gb=[math]::Round((Get-PSDrive C).Free/1GB,1)}
  rdp_port       = 3389
  rdp_user       = $u
  rdp_listen     = $listen
  rdp_denyts     = $okDeny
  started_at     = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  expires_at     = $now.AddMinutes($dur).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  duration_menit = $dur
  run_id         = $env:GITHUB_RUN_ID
  run_attempt    = $env:GITHUB_RUN_ATTEMPT
  run_number     = $env:GITHUB_RUN_NUMBER
  run_url        = "https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
  mode           = 'bersih+win10'
  akses          = @{ mode = 'tailscale'; tailscale = @{ status = 'pending' } }
}
$outDir = Join-Path (Get-Workspace) 'out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$status | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -Path (Join-Path $outDir 'rdp-status.json')
$now.ToString('s') | Set-Content -Path (Join-Path $outDir 'started.txt')
$status | ConvertTo-Json -Depth 8 | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY

Log "SESI DASAR SIAP — user $u, port 3389. Lanjut: setup akses (tunnel/Tailscale)."
exit 0
