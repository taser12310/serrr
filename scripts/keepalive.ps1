# ============================================================================
#  keepalive.ps1 — Jaga sesi tetap hidup sampai waktu habis + Auto-Checkpoint
# ----------------------------------------------------------------------------
#  1) Mengecek kesehatan listener RDP :3389 dan tunnel Tailscale/Portmap setiap
#     menit (auto-restart TermService bila listener drop).
#  2) Menjalankan Auto-Checkpoint (persist-state.ps1 -Checkpoint) setiap 15 menit
#     agar seluruh file user, world Minecraft (.minecraft), save/setting GTA SA-MP,
#     dan C:\Persist selalu tersimpan ke Release 'xyrdp-state-latest' walaupun
#     sesi dihentikan mendadak atau terkena batas waktu GitHub Actions.
#  3) Otomatis menyuntikkan OpenGL 4.6 (Mesa D3D12) bila runtime Java Minecraft
#     baru saja terunduh saat sesi berjalan, serta auto-patch SilentPatch bila
#     folder GTA San Andreas baru diekstrak user di tengah sesi.
# ============================================================================

$XyTag = 'XyRDP:keepalive'
. "$PSScriptRoot/lib-common.ps1"

$s = Read-Status
$exp = if ($s -and $s.expires_at) { [DateTime]::Parse($s.expires_at).ToUniversalTime() } else { [DateTime]::UtcNow.AddMinutes(335) }
Log "sesi aktif sampai $($exp.ToString('yyyy-MM-dd HH:mm:ss')) UTC (auto-checkpoint setiap 15 menit)"

$i = 0
$lastCheckpointUtc = [DateTime]::UtcNow
$checkpointJob = $null
$tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"

while ([DateTime]::UtcNow -lt $exp.AddMinutes(-3)) {
  if (Test-Path 'C:\stop.signal') { Log 'Sinyal stop diterima — keluar dari loop keepalive dengan aman.'; break }
  Start-Sleep -Seconds 60
  $i++
  $now = [DateTime]::UtcNow
  $rem = [int][math]::Max(0, ($exp - $now).TotalMinutes)

  # 1. Pastikan TermService, UmRdpService, & listener :3389 selalu sehat
  try {
    foreach ($svcName in @('TermService', 'UmRdpService')) {
      $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
      if ($svc -and $svc.Status -ne 'Running') {
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
        Log "$svcName di-start ulang otomatis."
      }
    }
    $tsReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    if ((Get-ItemPropertyValue $tsReg 'fDenyTSConnections' -ErrorAction SilentlyContinue) -ne 0) {
      Set-ItemProperty $tsReg 'fDenyTSConnections' 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  # 1b. Auto-heal Tailscale Tunnel setiap menit agar sesi HP tidak tiba-tiba terputus saat relay DERP berganti
  if (Test-Path $tsExe) {
    try {
      $tsSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
      if ($tsSvc -and $tsSvc.Status -ne 'Running') {
        Start-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
      }
      $tsRaw = & $tsExe status --json 2>$null | Out-String
      $tsObj = if ($tsRaw) { $tsRaw | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }
      $tsState = if ($tsObj) { [string]$tsObj.BackendState } else { '' }
      if ($tsState -and $tsState -ne 'Running' -and $env:TAILSCALE_AUTH_KEY) {
        Log "Tailscale state '$tsState' terdeteksi — memulihkan koneksi tunnel secara otomatis..."
        $hn = if ($s -and $s.hostname) { [string]$s.hostname } else { "xyrdp-$env:GITHUB_RUN_NUMBER" }
        & $tsExe up --authkey="$($env:TAILSCALE_AUTH_KEY.Trim())" --hostname=$hn --unattended --accept-routes --accept-dns=false --reset 2>&1 | Out-Null
      }
    } catch {}
  }

  # 2. Setiap 2 menit: jika user baru mengunduh runtime Java di .minecraft atau ekstrak GTA SA, suntikkan OpenGL 4.6 & SilentPatch
  if (($i % 2) -eq 0) {
    $deployGl = 'C:\XyRDP\grafis\Deploy-OpenGL-To-Java.ps1'
    if (Test-Path $deployGl) {
      try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployGl 2>&1 | Out-Null } catch {}
    }
  }

  # 3. Setiap 5 menit: log detak jantung + cek Tailscale
  if (($i % 5) -eq 0) {
    $tsIp = ''
    if (Test-Path $tsExe) {
      try { $tsIp = ((& $tsExe ip -4 2>$null) | Select-Object -First 1).Trim() } catch {}
    }
    $listen = Get-RdpListenerState 3389
    Log "detak #$i | sisa $rem menit | RDP=$listen | tailscale=$tsIp"
  }

  # 4. Setiap 15 menit: jalankan Auto-Checkpoint lintas sesi di background (non-blocking) ke Release 'xyrdp-state-latest'
  if (($now - $lastCheckpointUtc).TotalMinutes -ge 15 -and $rem -gt 4) {
    $canRun = $true
    if ($checkpointJob) {
      if ($checkpointJob.State -eq 'Running') {
        $canRun = $false
      } else {
        Remove-Job -Job $checkpointJob -Force -ErrorAction SilentlyContinue
        $checkpointJob = $null
      }
    }
    if ($canRun) {
      $lastCheckpointUtc = $now
      try {
        Log 'Menjalankan auto-checkpoint 15 menit di background (persist-state.ps1 -Checkpoint)...'
        $persistPath = Join-Path $PSScriptRoot 'persist-state.ps1'
        $checkpointJob = Start-Job -ScriptBlock {
          param($p)
          try { [System.Threading.Thread]::CurrentThread.Priority = [System.Threading.ThreadPriority]::Lowest } catch {}
          & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Checkpoint 2>&1 | Out-Null
        } -ArgumentList $persistPath
      } catch {
        Log "Auto-checkpoint warning: $($_.Exception.Message)"
      }
    }
  }
}

if ($checkpointJob) {
  try { Wait-Job -Job $checkpointJob -Timeout 25 | Out-Null } catch {}
  Remove-Job -Job $checkpointJob -Force -ErrorAction SilentlyContinue
}

Log 'Waktu sesi selesai dengan aman — lanjut ke penyimpanan akhir & estafet sesi berikutnya.'
exit 0
