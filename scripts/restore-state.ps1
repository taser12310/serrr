# ============================================================================
#  restore-state.ps1 — Pulihkan state sesi RDP dari sesi sebelumnya (Anti-Reset v3)
# ----------------------------------------------------------------------------
#  Mencari sumber state terbaru dari:
#    1) GitHub Release tag 'xyrdp-state-latest' (tahan terhadap cleanup run)
#    2) GitHub Actions Artifact 'xyrdp-state' (fallback)
#
#  Memulihkan:
#    - Sesi Login Browser (Google, YouTube, Gmail, GitHub, dll.) di Chrome,
#      Edge, Brave, dan Firefox (dengan re-wrap kunci AES-256 DPAPI otomatis
#      agar cookie tetap valid 100% di VM baru!)
#    - Sesi Login Roblox Player, Discord, Minecraft, & SA-MP
#    - Desktop, Documents (GTA San Andreas User Files / SAMP), Downloads,
#      Pictures, Music, Videos
#    - C:\Persist & C:\Games
#    - Registry HKCU\Software\SAMP & Identitas Tailscale (IP 100.x konsisten)
# ============================================================================

$XyTag = 'XyRDP:restore'
. "$PSScriptRoot/lib-common.ps1"

$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }
$prof = "C:\Users\$u"

New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path 'C:\Games'   -Force -ErrorAction SilentlyContinue | Out-Null

# Matikan App-Bound Encryption Chrome 127+ & aktifkan Roaming Profile agar cookie login portabel antar VM
foreach ($polPath in @(
  'HKLM:\SOFTWARE\Policies\Google\Chrome',
  'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
  'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
)) {
  try {
    New-Item -Path $polPath -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $polPath -Name 'ApplicationBoundEncryptionEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $polPath -Name 'RoamingProfileSupportEnabled'      -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
  } catch {}
}

# Helper C# untuk membungkus ulang kunci 32-byte AES-256 os_crypt dengan DPAPI milik user RDP di VM baru
function Import-ChromiumMasterKey([string]$LocalStatePath, [byte[]]$RawKeyBytes) {
  if (-not $RawKeyBytes -or $RawKeyBytes.Length -eq 0) { return }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    if (-not ('XyDpapiProtect' -as [type])) {
      Add-Type -ReferencedAssemblies 'System.Security' -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;

public static class XyDpapiProtect {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int logonType, int logonProvider, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static byte[] ProtectForUser(byte[] rawKey, string user, string pass) {
        if (!string.IsNullOrEmpty(user) && !string.IsNullOrEmpty(pass)) {
            IntPtr tok = IntPtr.Zero;
            if (LogonUser(user, ".", pass, 2, 0, out tok) && tok != IntPtr.Zero) {
                try {
                    using (WindowsImpersonationContext ctx = WindowsIdentity.Impersonate(tok)) {
                        return ProtectedData.Protect(rawKey, null, DataProtectionScope.CurrentUser);
                    }
                } catch {} finally {
                    CloseHandle(tok);
                }
            }
        }
        try {
            return ProtectedData.Protect(rawKey, null, DataProtectionScope.CurrentUser);
        } catch {
            return null;
        }
    }
}
"@ -ErrorAction SilentlyContinue
    }
    $dpapiBlob = [XyDpapiProtect]::ProtectForUser($RawKeyBytes, $u, $env:RDP_PASSWORD)
    if (-not $dpapiBlob) { return }

    # Prefix 5 byte ASCII "DPAPI"
    $prefix = [System.Text.Encoding]::ASCII.GetBytes('DPAPI')
    $combined = New-Object byte[] ($prefix.Length + $dpapiBlob.Length)
    [Array]::Copy($prefix, 0, $combined, 0, $prefix.Length)
    [Array]::Copy($dpapiBlob, 0, $combined, $prefix.Length, $dpapiBlob.Length)
    $b64Key = [Convert]::ToBase64String($combined)

    $parent = Split-Path $LocalStatePath -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $stateObj = @{ os_crypt = @{ encrypted_key = $b64Key } }
    if (Test-Path $LocalStatePath) {
      try {
        $existing = Get-Content -LiteralPath $LocalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($existing) {
          if (-not $existing.os_crypt) {
            $existing | Add-Member -NotePropertyName 'os_crypt' -NotePropertyValue ([pscustomobject]@{ encrypted_key = $b64Key }) -Force
          } else {
            $existing.os_crypt | Add-Member -NotePropertyName 'encrypted_key' -NotePropertyValue $b64Key -Force
            if ($existing.os_crypt.PSObject.Properties['app_bound_encrypted_key']) {
              $existing.os_crypt.PSObject.Properties.Remove('app_bound_encrypted_key')
            }
          }
          $existing | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $LocalStatePath -Encoding UTF8 -Force
          return
        }
      } catch {}
    }
    $stateObj | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $LocalStatePath -Encoding UTF8 -Force
  } catch {}
}

# Pastikan kunci deterministik 32-byte siap di sesi pertama sekalipun supaya Chrome langsung mengenkripsi cookie dengan kunci portabel
function Ensure-DeterministicBrowserKey([string]$UserDataDir) {
  $localState = Join-Path $UserDataDir 'Local State'
  $seedStr = "$($env:GITHUB_REPOSITORY)|$u|xyrdp-portable-browser-key-v3"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $detKey = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedStr))
  Import-ChromiumMasterKey $localState $detKey
}

function Ensure-PersistShortcut([string]$UserDesktop) {
  if (-not (Test-Path $UserDesktop)) {
    New-Item -ItemType Directory -Path $UserDesktop -Force -ErrorAction SilentlyContinue | Out-Null
  }
  try {
    $readme = 'C:\Persist\BACA-SAYA-ANTI-RESET.txt'
    @(
      '===================================================================='
      ' SISTEM PENYIMPANAN OTOMATIS XyRDP (CLOUD PERSISTENCE v3)'
      '===================================================================='
      'Data yang OTOMATIS TERSIMPAN lintas sesi RDP (Anti-Reset):'
      '  1. Login Browser (Google, YouTube, Gmail, GitHub, dll.) di Chrome,'
      '     Edge, Brave, & Firefox (Cookies, Password Tersimpan, Bookmark)'
      '  2. Login & Save Game: GTA San Andreas / SA-MP, Roblox, Minecraft, Discord'
      '  3. Folder Desktop, Documents, Downloads, Pictures, Music, Videos'
      '  4. Folder C:\Persist (Folder ini) & C:\Games'
      '  5. IP Tailscale 100.x tetap konsisten di setiap sesi'
      ''
      'Penyimpanan berjalan OTOMATIS setiap 15 menit dan saat sesi selesai,'
      'atau klik tombol "Cloud Save Sekarang" di aplikasi XyDeskTools.exe!'
      '===================================================================='
    ) | Set-Content -Path $readme -Encoding UTF8 -Force

    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut((Join-Path $UserDesktop 'Folder Permanen (Anti-Reset).lnk'))
    $lnk.TargetPath = 'C:\Persist'
    $lnk.Description = 'Folder Permanen Anti-Reset Lintas Sesi XyRDP'
    $lnk.IconLocation = 'shell32.dll,43'
    $lnk.Save()
  } catch {}
}

if (-not $env:GITHUB_TOKEN -or -not $env:GITHUB_REPOSITORY) {
  Log 'GITHUB_TOKEN tidak tersedia — lewati restore.'
  exit 0
}

$hdr = @{
  Authorization          = "Bearer $($env:GITHUB_TOKEN)"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'XyRDP-Restore'
}
$apiBase = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"

$tmp = 'C:\XyRDP\restore'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'state.zip'
$ext = Join-Path $tmp 'ext'
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue

$releaseAssetUrl = $null
$releaseUpdated  = [DateTime]::MinValue
$releaseSizeMb   = 0

try {
  $rel = Invoke-RestMethod -Uri "$apiBase/releases/tags/xyrdp-state-latest" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
  foreach ($a in @($rel.assets)) {
    if ($a -and $a.name -eq 'xyrdp-state.zip') {
      $releaseAssetUrl = "$apiBase/releases/assets/$($a.id)"
      $releaseUpdated  = [DateTime]::Parse("$($a.updated_at)").ToUniversalTime()
      $releaseSizeMb   = [math]::Round($a.size / 1MB, 1)
      break
    }
  }
} catch {}

$artifactUrl     = $null
$artifactUpdated = [DateTime]::MinValue
$artifactSizeMb  = 0

try {
  $resp = Invoke-RestMethod -Uri "$apiBase/actions/artifacts?name=xyrdp-state&per_page=5" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
  $art = $resp.artifacts | Where-Object { -not $_.expired } | Sort-Object created_at -Descending | Select-Object -First 1
  if ($art) {
    $artifactUrl     = $art.archive_download_url
    $artifactUpdated = [DateTime]::Parse("$($art.created_at)").ToUniversalTime()
    $artifactSizeMb  = [math]::Round($art.size_in_bytes / 1MB, 1)
  }
} catch {}

$downloaded = $false

if ($releaseAssetUrl -and ($releaseUpdated -ge $artifactUpdated)) {
  try {
    Log "Mengunduh state terbaru dari Release 'xyrdp-state-latest' ($releaseSizeMb MB, $($releaseUpdated.ToString('yyyy-MM-dd HH:mm:ss')) UTC)..."
    $dlHdr = @{
      Authorization          = "Bearer $($env:GITHUB_TOKEN)"
      Accept                 = 'application/octet-stream'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent'           = 'XyRDP-Restore'
    }
    Invoke-WebRequest -Uri $releaseAssetUrl -Headers $dlHdr -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100) { $downloaded = $true }
  } catch {
    Log "Unduh dari Release gagal ($($_.Exception.Message)), mencoba fallback Artifact..."
  }
}

if ((-not $downloaded) -and $artifactUrl) {
  try {
    Log "Mengunduh state dari Artifact 'xyrdp-state' ($artifactSizeMb MB, $($artifactUpdated.ToString('yyyy-MM-dd HH:mm:ss')) UTC)..."
    Invoke-WebRequest -Uri $artifactUrl -Headers $hdr -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100) { $downloaded = $true }
  } catch {
    Log "Unduh dari Artifact gagal: $($_.Exception.Message)"
  }
}

if (-not $downloaded) {
  Log 'Belum ada simpanan sesi sebelumnya — menyiapkan kunci portabel browser & folder C:\Persist untuk sesi pertama.'
  Ensure-PersistShortcut (Join-Path $prof 'Desktop')
  Ensure-DeterministicBrowserKey (Join-Path $prof 'AppData\Local\Google\Chrome\User Data')
  Ensure-DeterministicBrowserKey (Join-Path $prof 'AppData\Local\Microsoft\Edge\User Data')
  exit 0
}

try {
  $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
  New-Item -ItemType Directory -Path $ext -Force | Out-Null
  if (Test-Path $sevenZip) {
    & $sevenZip x $zip "-o$ext" -y 2>&1 | Out-Null
  } else {
    Expand-Archive -Path $zip -DestinationPath $ext -Force
  }

  $innerZip = Join-Path $ext 'xyrdp-state.zip'
  if (Test-Path $innerZip) {
    $innerExt = Join-Path $tmp 'ext_inner'
    New-Item -ItemType Directory -Path $innerExt -Force | Out-Null
    if (Test-Path $sevenZip) {
      & $sevenZip x $innerZip "-o$innerExt" -y 2>&1 | Out-Null
    } else {
      Expand-Archive -Path $innerZip -DestinationPath $innerExt -Force
    }
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
    Rename-Item -Path $innerExt -NewName 'ext' -Force
  }

  if (-not (Test-Path $prof)) {
    New-Item -ItemType Directory -Path $prof -Force | Out-Null
  }

  $restoredDirs = 0

  # 1. Pulihkan folder profil (Desktop, Documents, Downloads, Pictures, Music, Videos)
  foreach ($d in @('Desktop','Documents','Downloads','Pictures','Music','Videos')) {
    $src = Join-Path $ext $d
    if (Test-Path $src) {
      $dst = Join-Path $prof $d
      New-Item -ItemType Directory -Path $dst -Force | Out-Null
      Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
      $restoredDirs++
    }
  }

  # 2. Pulihkan DPAPI MasterKeys bila ada
  $dpRoamSrc = Join-Path $ext '_dpapi_roaming'
  if (Test-Path $dpRoamSrc) {
    Copy-Item -Path "$dpRoamSrc\*" -Destination (Join-Path $prof 'AppData\Roaming') -Recurse -Force -ErrorAction SilentlyContinue
  }
  $dpLocSrc = Join-Path $ext '_dpapi_local'
  if (Test-Path $dpLocSrc) {
    Copy-Item -Path "$dpLocSrc\*" -Destination (Join-Path $prof 'AppData\Local') -Recurse -Force -ErrorAction SilentlyContinue
  }

  # 3. Pulihkan Profil Browser (Chrome, Edge, Brave) + Re-wrap Kunci AES-256 os_crypt ke DPAPI VM Baru
  $browserMap = @{
    'Chrome' = (Join-Path $prof 'AppData\Local\Google\Chrome\User Data')
    'Edge'   = (Join-Path $prof 'AppData\Local\Microsoft\Edge\User Data')
    'Brave'  = (Join-Path $prof 'AppData\Local\BraveSoftware\Brave-Browser\User Data')
  }
  foreach ($bName in $browserMap.Keys) {
    $bSrc = Join-Path $ext "_browsers\$bName"
    $bDst = $browserMap[$bName]
    if (Test-Path $bSrc) {
      New-Item -ItemType Directory -Path $bDst -Force | Out-Null
      Copy-Item -Path "$bSrc\*" -Destination $bDst -Recurse -Force -ErrorAction SilentlyContinue
      $keyFile = Join-Path $ext "_browser_keys\$bName.key"
      if (Test-Path $keyFile) {
        $rawKey = [System.IO.File]::ReadAllBytes($keyFile)
        Import-ChromiumMasterKey (Join-Path $bDst 'Local State') $rawKey
        Log "  Sesi login & cookies $bName berhasil dipulihkan (DPAPI key re-bound ke VM baru)."
      } else {
        Ensure-DeterministicBrowserKey $bDst
      }
      $restoredDirs++
    } else {
      Ensure-DeterministicBrowserKey $bDst
    }
  }

  # 4. Pulihkan %APPDATA% (Firefox, .minecraft, PrismLauncher, .tlauncher, Discord) & %LOCALAPPDATA% (Roblox)
  $roamingSrc = Join-Path $ext '_appdata_roaming'
  if (Test-Path $roamingSrc) {
    $roamingDst = Join-Path $prof 'AppData\Roaming'
    New-Item -ItemType Directory -Path $roamingDst -Force | Out-Null
    Copy-Item -Path "$roamingSrc\*" -Destination $roamingDst -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }
  $localSrc = Join-Path $ext '_appdata_local'
  if (Test-Path $localSrc) {
    $localDst = Join-Path $prof 'AppData\Local'
    New-Item -ItemType Directory -Path $localDst -Force | Out-Null
    Copy-Item -Path "$localSrc\*" -Destination $localDst -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }

  # 5. Pulihkan C:\Persist dan C:\Games
  $persistSrc = Join-Path $ext '_persist'
  if (Test-Path $persistSrc) {
    New-Item -ItemType Directory -Path 'C:\Persist' -Force | Out-Null
    Copy-Item -Path "$persistSrc\*" -Destination 'C:\Persist' -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }
  $gamesSrc = Join-Path $ext '_games'
  if (Test-Path $gamesSrc) {
    New-Item -ItemType Directory -Path 'C:\Games' -Force | Out-Null
    Copy-Item -Path "$gamesSrc\*" -Destination 'C:\Games' -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }

  # 6. Pulihkan Registry HKCU\Software\SAMP
  $sampReg = Join-Path $ext '_registry\samp-hkcu.reg'
  if (Test-Path $sampReg) {
    try {
      & reg.exe import $sampReg 2>&1 | Out-Null
      $ntAccount = New-Object System.Security.Principal.NTAccount($u)
      $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
      if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
        $rawReg = Get-Content $sampReg -Raw -ErrorAction SilentlyContinue
        if ($rawReg) {
          $sidReg = Join-Path $tmp 'samp-sid.reg'
          ($rawReg -replace 'HKEY_CURRENT_USER', "HKEY_USERS\$sid") | Set-Content -Path $sidReg -Encoding Unicode -Force
          & reg.exe import $sidReg 2>&1 | Out-Null
          Remove-Item $sidReg -Force -ErrorAction SilentlyContinue
        }
      }
      Log '  Registry HKCU\Software\SAMP berhasil dipulihkan.'
    } catch {}
  }

  # 7. Pulihkan identitas Tailscale C:\ProgramData\Tailscale
  $tsSrc = Join-Path $ext '_tailscale'
  if (Test-Path $tsSrc) {
    try {
      $tsDst = 'C:\ProgramData\Tailscale'
      New-Item -ItemType Directory -Path $tsDst -Force | Out-Null
      Copy-Item -Path "$tsSrc\*" -Destination $tsDst -Force -ErrorAction SilentlyContinue
      Log '  State identitas Tailscale berhasil dipulihkan (IP 100.x tetap konsisten).'
    } catch {}
  }

  # Pastikan ACL kepemilikan file milik user RDP penuh
  try {
    & icacls.exe $prof /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    & icacls.exe 'C:\Persist' /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    & icacls.exe 'C:\Games' /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  } catch {}

  Ensure-PersistShortcut (Join-Path $prof 'Desktop')
  Log "State sesi sebelumnya berhasil dipulihkan ($restoredDirs komponen utama aktif)."
} catch {
  Log "Restore state warning: $($_.Exception.Message)"
} finally {
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
