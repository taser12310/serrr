# ============================================================================
#  persist-state.ps1 — Simpan state sesi RDP lintas sesi (Anti-Reset v3)
# ----------------------------------------------------------------------------
#  Menyimpan:
#    1) Sesi Login Browser (Google, YouTube, Gmail, GitHub, Facebook, dll.):
#       - Google Chrome, Microsoft Edge, Brave Browser:
#         Cookies, Login Data, Web Data, Preferences, Secure Preferences,
#         Local Storage, Session Storage, Sessions, IndexedDB, Bookmarks,
#         serta ekstraksi kunci AES-256 os_crypt portabel (_browser_keys)
#         agar cookie TIDAK ter-reset oleh DPAPI saat pindah VM baru!
#       - Mozilla Firefox (cookies.sqlite, logins.json, key4.db, places.sqlite)
#    2) Sesi Login Aplikasi & Game:
#       - Roblox Player (%LOCALAPPDATA%\Roblox\LocalStorage & GlobalBasicSettings)
#       - Discord (%APPDATA%\discord\Local Storage & Session Storage)
#       - GTA San Andreas & SA-MP (Documents\GTA San Andreas User Files + HKCU\Software\SAMP)
#       - Minecraft (%APPDATA%\.minecraft, PrismLauncher, .tlauncher)
#    3) Profil & Folder Permanen User RDP ($env:RDP_USER):
#       - Desktop, Documents, Downloads, Pictures, Music, Videos
#       - C:\Persist & C:\Games
#    4) Identitas Node Tailscale (C:\ProgramData\Tailscale):
#       - Agar sesi berikutnya tetap mendapatkan IP Tailscale 100.x yang sama
# ============================================================================
param(
  [switch]$Checkpoint
)

$XyTag = if ($Checkpoint) { 'XyRDP:checkpoint' } else { 'XyRDP:persist' }
. "$PSScriptRoot/lib-common.ps1"

$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }
$prof = "C:\Users\$u"
$outDir = 'C:\XyRDP\persist'
$stage  = Join-Path $outDir 'stage'
$zip    = Join-Path $outDir 'xyrdp-state.zip'
# Saat Checkpoint berkala di tengah sesi, batasi ukuran hingga 180 MB agar hemat RAM/CPU & tidak mengganggu game/browser.
# Saat finalisasi akhir sesi, izinkan hingga 850 MB.
$maxBytes = if ($Checkpoint) { 180L * 1024 * 1024 } else { 850L * 1024 * 1024 }
$maxSingleFileBytes = if ($Checkpoint) { 45MB } else { 350MB }

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
if (-not $Checkpoint) {
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null

$skipExts = @('.iso','.wim','.vhd','.vhdx','.vmdk','.dmp','.tmp','.part','.crdownload','.pma')
$skipDirs = @('cache','caches','code cache','gpucache','shadercache','dawngraphitecache','dawnwebgpucache','grshadercache','crashpad','logs','temp','tmp','webcache','blob_storage','crash-reports','service worker','cache_data')

$script:totalBytes = 0L
$script:totalFiles = 0

# Salin file meskipun sedang dikunci oleh Chrome/Edge/Game (FileShare.ReadWrite | FileShare.Delete)
function Copy-SharedFile([string]$SrcFile, [string]$DstFile) {
  try {
    $parent = Split-Path $DstFile -Parent
    if (-not (Test-Path $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $SrcFile -Destination $DstFile -Force -ErrorAction Stop
    return $true
  } catch {
    try {
      $inStream = [System.IO.File]::Open($SrcFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
      try {
        $outStream = [System.IO.File]::Open($DstFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
          $inStream.CopyTo($outStream)
          return $true
        } finally {
          $outStream.Dispose()
        }
      } finally {
        $inStream.Dispose()
      }
    } catch {
      return $false
    }
  }
}

function Copy-FilteredTree([string]$SrcRoot, [string]$DstRoot, [string]$Label) {
  if (-not (Test-Path $SrcRoot)) { return }
  $rootPath = (Get-Item $SrcRoot -Force).FullName.TrimEnd('\')
  Get-ChildItem -Path $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      if ($_.Name -eq 'desktop.ini' -or $_.Name -eq 'thumbs.db' -or $_.Name -eq 'lockfile') { return }
      $ext = $_.Extension.ToLower()
      if ($skipExts -contains $ext) { return }
      if ($_.Length -gt $maxSingleFileBytes) { return }
      if (($script:totalBytes + $_.Length) -gt $maxBytes) { return }

      $rel = $_.FullName.Substring($rootPath.Length).TrimStart('\')
      $parts = $rel -split '[\\/]'
      foreach ($p in $parts) {
        if ($skipDirs -contains $p.ToLower()) { return }
      }

      $dest = Join-Path $DstRoot $rel
      if (Copy-SharedFile $_.FullName $dest) {
        $script:totalBytes += $_.Length
        $script:totalFiles++
      }
    } catch {}
  }
}

# Helper C# untuk mengekstrak kunci AES-256 os_crypt Chrome/Edge menggunakan impersonasi user RDP
function Export-ChromiumMasterKey([string]$LocalStatePath, [string]$KeyOutPath) {
  if (-not (Test-Path $LocalStatePath)) { return }
  try {
    $rawJson = Get-Content -LiteralPath $LocalStatePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $encB64 = $rawJson.os_crypt.encrypted_key
    if (-not $encB64) { return }
    $encBytes = [Convert]::FromBase64String($encB64)
    if ($encBytes.Length -le 5) { return }
    # Hapus prefix 5 byte "DPAPI"
    $dpapiBlob = $encBytes[5..($encBytes.Length - 1)]

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    if (-not ('XyDpapiUnprotect' -as [type])) {
      Add-Type -ReferencedAssemblies 'System.Security' -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;

public static class XyDpapiUnprotect {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int logonType, int logonProvider, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static byte[] UnprotectForUser(byte[] blob, string user, string pass) {
        try {
            return ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser);
        } catch {}
        if (!string.IsNullOrEmpty(user) && !string.IsNullOrEmpty(pass)) {
            IntPtr tok = IntPtr.Zero;
            if (LogonUser(user, ".", pass, 2, 0, out tok) && tok != IntPtr.Zero) {
                try {
                    using (WindowsImpersonationContext ctx = WindowsIdentity.Impersonate(tok)) {
                        return ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser);
                    }
                } catch {} finally {
                    CloseHandle(tok);
                }
            }
        }
        return null;
    }
}
"@ -ErrorAction SilentlyContinue
    }
    $rawKey = [XyDpapiUnprotect]::UnprotectForUser($dpapiBlob, $u, $env:RDP_PASSWORD)
    if ($rawKey -and $rawKey.Length -gt 0) {
      $parent = Split-Path $KeyOutPath -Parent
      if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      [System.IO.File]::WriteAllBytes($KeyOutPath, $rawKey)
      $script:totalFiles++
    }
  } catch {}
}

# Simpan profil penting Chromium (Chrome, Edge, Brave) tanpa cache raksasa
function Save-ChromiumBrowser([string]$BrowserName, [string]$UserDataRoot) {
  if (-not (Test-Path $UserDataRoot)) { return }
  $dstBrowser = Join-Path $stage "_browsers\$BrowserName"
  New-Item -ItemType Directory -Path $dstBrowser -Force | Out-Null

  $localState = Join-Path $UserDataRoot 'Local State'
  if (Test-Path $localState) {
    if (Copy-SharedFile $localState (Join-Path $dstBrowser 'Local State')) {
      $script:totalFiles++
    }
    Export-ChromiumMasterKey $localState (Join-Path $stage "_browser_keys\$BrowserName.key")
  }

  # Cari profil Default dan Profile *
  $profDirs = Get-ChildItem -Path $UserDataRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'Default' -or $_.Name -like 'Profile *'
  }
  foreach ($pd in $profDirs) {
    $dstProf = Join-Path $dstBrowser $pd.Name
    New-Item -ItemType Directory -Path $dstProf -Force | Out-Null

    # File SQLite & JSON sesi login utama
    foreach ($fName in @(
      'Cookies','Network\Cookies','Network\Cookies-journal',
      'Login Data','Login Data-journal','Login Data For Account','Login Data For Account-journal',
      'Web Data','Web Data-journal','Preferences','Secure Preferences',
      'Bookmarks','History','Favicons','Shortcuts','Visited Links'
    )) {
      $srcF = Join-Path $pd.FullName $fName
      if (Test-Path $srcF) {
        $dstF = Join-Path $dstProf $fName
        if (Copy-SharedFile $srcF $dstF) {
          $script:totalBytes += (Get-Item $srcF -Force -ErrorAction SilentlyContinue).Length
          $script:totalFiles++
        }
      }
    }

    # Subfolder penyimpanan sesi web (Google, Discord Web, WhatsApp Web, Roblox Web, Ekstensi)
    foreach ($subName in @('Local Storage','Session Storage','Sessions','IndexedDB','Extension State','Local Extension Settings','Sync Data')) {
      $srcSub = Join-Path $pd.FullName $subName
      if (Test-Path $srcSub) {
        Copy-FilteredTree $srcSub (Join-Path $dstProf $subName) "$BrowserName\$($pd.Name)\$subName"
      }
    }
  }
}

# 1. Folder profil utama user RDP + Browser + Game
if (Test-Path $prof) {
  foreach ($d in @('Desktop','Documents','Downloads','Pictures','Music','Videos')) {
    Copy-FilteredTree (Join-Path $prof $d) (Join-Path $stage $d) $d
  }

  # 2. Browser Login & Cookies (Chrome, Edge, Brave, Firefox)
  $localAppData = Join-Path $prof 'AppData\Local'
  Save-ChromiumBrowser 'Chrome' (Join-Path $localAppData 'Google\Chrome\User Data')
  Save-ChromiumBrowser 'Edge'   (Join-Path $localAppData 'Microsoft\Edge\User Data')
  Save-ChromiumBrowser 'Brave'  (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data')

  $roaming = Join-Path $prof 'AppData\Roaming'
  $ffDir = Join-Path $roaming 'Mozilla\Firefox'
  if (Test-Path $ffDir) {
    Copy-FilteredTree $ffDir (Join-Path $stage '_appdata_roaming\Mozilla\Firefox') 'Firefox'
  }

  # 3. Simpan DPAPI MasterKeys user (%APPDATA%\Microsoft\Protect & Credentials) sebagai cadangan berlapis
  foreach ($dpSub in @('Microsoft\Protect','Microsoft\Credentials','Microsoft\Crypto')) {
    $srcDp = Join-Path $roaming $dpSub
    if (Test-Path $srcDp) {
      Copy-FilteredTree $srcDp (Join-Path $stage "_dpapi_roaming\$dpSub") $dpSub
    }
    $srcDpLocal = Join-Path $localAppData $dpSub
    if (Test-Path $srcDpLocal) {
      Copy-FilteredTree $srcDpLocal (Join-Path $stage "_dpapi_local\$dpSub") $dpSub
    }
  }

  # 4. Minecraft, Roblox, Discord data
  foreach ($appDir in @('.minecraft','PrismLauncher','.tlauncher')) {
    $srcApp = Join-Path $roaming $appDir
    if (Test-Path $srcApp) {
      Copy-FilteredTree $srcApp (Join-Path $stage "_appdata_roaming\$appDir") "Roaming\$appDir"
    }
  }
  foreach ($discSub in @('discord\Local Storage','discord\Session Storage','discord\settings.json')) {
    $srcDisc = Join-Path $roaming $discSub
    if (Test-Path $srcDisc) {
      if ((Get-Item $srcDisc).PSIsContainer) {
        Copy-FilteredTree $srcDisc (Join-Path $stage "_appdata_roaming\$discSub") "Discord"
      } else {
        Copy-SharedFile $srcDisc (Join-Path $stage "_appdata_roaming\$discSub") | Out-Null
      }
    }
  }
  foreach ($rbxSub in @('Roblox\LocalStorage','Roblox\GlobalBasicSettings_13.xml','Bloxstrap')) {
    $srcRbx = Join-Path $localAppData $rbxSub
    if (Test-Path $srcRbx) {
      if ((Get-Item $srcRbx).PSIsContainer) {
        Copy-FilteredTree $srcRbx (Join-Path $stage "_appdata_local\$rbxSub") "Roblox"
      } else {
        Copy-SharedFile $srcRbx (Join-Path $stage "_appdata_local\$rbxSub") | Out-Null
      }
    }
  }
}

# 5. Folder Permanen C:\Persist & C:\Games (C:\Games hanya disalin saat penutupan sesi, bukan saat checkpoint berkala agar bebas lag)
if (Test-Path 'C:\Persist') {
  Copy-FilteredTree 'C:\Persist' (Join-Path $stage '_persist') 'C:\Persist'
}
if ((-not $Checkpoint) -and (Test-Path 'C:\Games')) {
  Copy-FilteredTree 'C:\Games' (Join-Path $stage '_games') 'C:\Games'
}

# 6. Ekspor Registry HKCU\Software\SAMP
try {
  $regDir = Join-Path $stage '_registry'
  New-Item -ItemType Directory -Path $regDir -Force | Out-Null
  $sampRegOut = Join-Path $regDir 'samp-hkcu.reg'
  & reg.exe export 'HKCU\Software\SAMP' $sampRegOut /y 2>&1 | Out-Null

  try {
    $ntAccount = New-Object System.Security.Principal.NTAccount($u)
    $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid\Software\SAMP")) {
      $sampSidOut = Join-Path $regDir 'samp-user.reg'
      & reg.exe export "HKU\$sid\Software\SAMP" $sampSidOut /y 2>&1 | Out-Null
      if (Test-Path $sampSidOut) {
        $rawReg = Get-Content $sampSidOut -Raw -ErrorAction SilentlyContinue
        if ($rawReg) {
          ($rawReg -replace [regex]::Escape("HKEY_USERS\$sid"), 'HKEY_CURRENT_USER') | Set-Content -Path $sampRegOut -Encoding Unicode -Force
          Remove-Item $sampSidOut -Force -ErrorAction SilentlyContinue
        }
      }
      $script:totalFiles++
    }
  } catch {}
} catch {}

# 7. Simpan state Tailscale (server-state.conf) agar IP Tailscale 100.x tidak berubah antar sesi
try {
  $tsData = 'C:\ProgramData\Tailscale'
  if (Test-Path $tsData) {
    $tsDst = Join-Path $stage '_tailscale'
    New-Item -ItemType Directory -Path $tsDst -Force | Out-Null
    Get-ChildItem -Path $tsData -File -Force -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '\.(conf|json|key|state)$' -and $_.Length -lt 5MB
    } | ForEach-Object {
      Copy-SharedFile $_.FullName (Join-Path $tsDst $_.Name) | Out-Null
      $script:totalFiles++
    }
  }
} catch {}

if ($script:totalFiles -eq 0) {
  if (-not $Checkpoint) { Log 'Tidak ada file baru untuk disimpan.' }
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

@{
  user       = $u
  saved_at   = [DateTime]::UtcNow.ToString('o')
  run_id     = $env:GITHUB_RUN_ID
  checkpoint = [bool]$Checkpoint
  files      = $script:totalFiles
  bytes      = $script:totalBytes
} | ConvertTo-Json | Set-Content (Join-Path $stage '_meta.json') -Encoding UTF8

$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$tmpZip = Join-Path $outDir 'xyrdp-state-tmp.zip'
Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

try {
  if (Test-Path $sevenZip) {
    $mtArg = if ($Checkpoint) { '-mmt=1' } else { '-mmt=2' }
    & $sevenZip a -tzip -mx=1 $mtArg -ssw $tmpZip "$stage\*" 2>&1 | Out-Null
  } else {
    Compress-Archive -Path "$stage\*" -DestinationPath $tmpZip -CompressionLevel Fastest -Force
  }
  if (Test-Path $tmpZip) {
    Move-Item -Path $tmpZip -Destination $zip -Force
    $szMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Log "State (Login Browser + Game + File) berhasil dikemas: $($script:totalFiles) file ($([math]::Round($script:totalBytes/1MB,1)) MB -> zip $szMb MB)"
  }
} catch {
  Log "Kompresi state gagal: $($_.Exception.Message)"
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# Upload ke GitHub Release Tag 'xyrdp-state-latest' (gunakan curl.exe streaming agar tidak memakan RAM PowerShell)
if ((Test-Path $zip) -and $env:GITHUB_TOKEN -and $env:GITHUB_REPOSITORY) {
  try {
    $apiBase = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"
    $hdr = @{
      Authorization          = "Bearer $($env:GITHUB_TOKEN)"
      Accept                 = 'application/vnd.github+json'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent'           = 'XyRDP-Persist'
    }
    $tagName = 'xyrdp-state-latest'
    $rel = $null
    try {
      $rel = Invoke-RestMethod -Uri "$apiBase/releases/tags/$tagName" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
    } catch {}

    if (-not $rel) {
      $body = @{
        tag_name   = $tagName
        name       = 'XyRDP Persistent Session State (Auto-Save)'
        body       = 'Arsip otomatis penyimpanan data sesi XyRDP lintas sesi (Login Browser Chrome/Edge/Google, Save Game SA-MP/Roblox/Minecraft, Desktop, Documents, C:\Persist).'
        draft      = $false
        prerelease = $true
      } | ConvertTo-Json
      $rel = Invoke-RestMethod -Uri "$apiBase/releases" -Headers $hdr -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 25 -ErrorAction Stop
    }

    if ($rel -and $rel.id) {
      foreach ($asset in @($rel.assets)) {
        if ($asset -and $asset.name -eq 'xyrdp-state.zip') {
          try {
            Invoke-RestMethod -Uri "$apiBase/releases/assets/$($asset.id)" -Headers $hdr -Method Delete -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
          } catch {}
        }
      }
      $uploadUrl = ($rel.upload_url -replace '\{\?name,label\}$', '') + '?name=xyrdp-state.zip'
      $curlExe = "$env:SystemRoot\System32\curl.exe"
      if (Test-Path $curlExe) {
        & $curlExe -sS -X POST `
          -H "Authorization: Bearer $($env:GITHUB_TOKEN)" `
          -H "Accept: application/vnd.github+json" `
          -H "Content-Type: application/zip" `
          -H "X-GitHub-Api-Version: 2022-11-28" `
          -H "User-Agent: XyRDP-Persist" `
          --max-time 180 `
          --data-binary "@$zip" `
          "$uploadUrl" 2>&1 | Out-Null
      } else {
        $upHdr = @{
          Authorization          = "Bearer $($env:GITHUB_TOKEN)"
          Accept                 = 'application/vnd.github+json'
          'Content-Type'         = 'application/zip'
          'X-GitHub-Api-Version' = '2022-11-28'
          'User-Agent'           = 'XyRDP-Persist'
        }
        Invoke-RestMethod -Uri $uploadUrl -Headers $upHdr -Method Post -InFile $zip -TimeoutSec 180 -ErrorAction Stop | Out-Null
      }
      Log "State berhasil di-backup ke Release '$tagName' (anti-reset lintas sesi aktif)."
    }
  } catch {
    Log "Backup ke Release '$tagName' dilewati: $($_.Exception.Message)"
  }
}
exit 0
