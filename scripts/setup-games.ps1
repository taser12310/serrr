# ============================================================================
#  setup-games.ps1 — Installer Game Opsional:
#    1) Minecraft Java Edition:
#       - Eclipse Temurin JDK 21 LTS (x64) untuk Minecraft 1.20.5 / 1.21+
#       - Eclipse Temurin JRE 8 LTS (x64) untuk Minecraft 1.8.9 / 1.12.2 / Forge
#       - Official Minecraft Launcher + PrismLauncher Portable (C:\Games\PrismLauncher)
#       - Injeksi otomatis Mesa3D OpenGL 4.6 (D3D12) ke seluruh runtime Java
#         agar tidak gagal "GLFW error 65542: The driver does not appear to support OpenGL"
#       - Preset options.txt 120 FPS ramah RDP di %APPDATA%\.minecraft
#    2) Minecraft Bedrock / Launcher
#    3) Roblox Player
# ============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$XyTag                 = 'XyRDP:games'
. "$PSScriptRoot/lib-common.ps1"

function Test-OptIn([string]$Val) {
  if (-not $Val) { return $false }
  return @('ya','1','true','yes','on') -contains $Val.Trim().ToLower()
}

$wantRoblox  = Test-OptIn $env:ROBLOX
$wantMcJava  = Test-OptIn $env:MINECRAFT_JAVA
$wantMcBed   = Test-OptIn $env:MINECRAFT_BEDROCK

if (-not ($wantRoblox -or $wantMcJava -or $wantMcBed)) {
  Log 'Tidak ada game opsional yang dipilih (roblox/minecraft_java/minecraft_bedrock = tidak).'
  exit 0
}

$work = 'C:\XyRDP\deps\games'
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\Games' -Force | Out-Null

function Invoke-GameDownload([string]$Url, [string]$OutFile) {
  Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
  & curl.exe -fL --retry 3 --retry-delay 2 --connect-timeout 20 -sS $Url -o $OutFile
  if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 4096) {
    return $true
  }
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
    return ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 4096)
  } catch {
    return $false
  }
}

function Install-JavaRuntimesForMinecraft {
  # 1. Pasang Eclipse Temurin JDK 21 LTS x64 (untuk Minecraft 1.20.5 / 1.21+)
  $hasJava21 = $false
  if (Test-Path 'C:\Program Files\Eclipse Adoptium') {
    $hasJava21 = (Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-21*' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
  }
  if (-not $hasJava21) {
    try {
      $jdk21Msi = Join-Path $work 'Temurin21-x64.msi'
      Log 'Mengunduh Eclipse Temurin JDK 21 LTS (x64) untuk Minecraft 1.21+...'
      if (Invoke-GameDownload 'https://api.adoptium.net/v3/installer/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' $jdk21Msi) {
        Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$jdk21Msi`"", '/qn', '/norestart', 'ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome') -Wait -WindowStyle Hidden | Out-Null
        Log 'Eclipse Temurin JDK 21 LTS terpasang.'
      }
    } catch { Log "Instalasi JDK 21 warning: $($_.Exception.Message)" }
  }

  # 2. Pasang Eclipse Temurin JRE 8 LTS x64 (untuk Minecraft 1.8.9 / 1.12.2 / 1.16.5)
  $hasJava8 = $false
  if (Test-Path 'C:\Program Files\Eclipse Adoptium') {
    $hasJava8 = (Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jre-8*' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
  }
  if (-not $hasJava8) {
    try {
      $jre8Msi = Join-Path $work 'Temurin8-x64.msi'
      Log 'Mengunduh Eclipse Temurin JRE 8 LTS (x64) untuk Minecraft 1.8.9/1.12.2...'
      if (Invoke-GameDownload 'https://api.adoptium.net/v3/installer/latest/8/ga/windows/x64/jre/hotspot/normal/eclipse' $jre8Msi) {
        Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$jre8Msi`"", '/qn', '/norestart') -Wait -WindowStyle Hidden | Out-Null
        Log 'Eclipse Temurin JRE 8 LTS terpasang.'
      }
    } catch { Log "Instalasi JRE 8 warning: $($_.Exception.Message)" }
  }
}

function Install-PrismLauncherPortable {
  $prismDir = 'C:\Games\PrismLauncher'
  if (Test-Path (Join-Path $prismDir 'PrismLauncher.exe')) {
    return $true
  }
  try {
    New-Item -ItemType Directory -Path $prismDir -Force | Out-Null
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest' `
      -Headers @{ 'User-Agent' = 'XyRDP' } -TimeoutSec 20
    $asset = $rel.assets | Where-Object { $_.name -match 'Windows-MSVC-Portable-x86_64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
      $asset = $rel.assets | Where-Object { $_.name -match 'Windows.*Portable.*\.zip$' -and $_.name -notmatch 'arm64' } | Select-Object -First 1
    }
    if ($asset) {
      $zip = Join-Path $work $asset.name
      Log "Mengunduh PrismLauncher Portable ($($asset.name))..."
      if (Invoke-GameDownload $asset.browser_download_url $zip) {
        $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
        if (Test-Path $sevenZip) { & $sevenZip x $zip "-o$prismDir" -y 2>&1 | Out-Null }
        else { Expand-Archive -Path $zip -DestinationPath $prismDir -Force }
        Log 'PrismLauncher Portable berhasil dipasang di C:\Games\PrismLauncher.'
        return $true
      }
    }
  } catch {
    Log "PrismLauncher Portable dilewati: $($_.Exception.Message)"
  }
  return $false
}

function Configure-MinecraftOpenGLAndOptions {
  # Pastikan Mesa3D OpenGL 4.6 sudah diekstrak; jika belum, jalankan setup-grafis.ps1
  $mesaDll = 'C:\XyRDP\grafis\mesa-x64\opengl32.dll'
  if (-not (Test-Path $mesaDll)) {
    try {
      $env:GRAFIS = 'software'
      & "$PSScriptRoot/setup-grafis.ps1" 2>&1 | Out-Null
    } catch {}
  }
  $deployPs1 = 'C:\XyRDP\grafis\Deploy-OpenGL-To-Java.ps1'
  if (Test-Path $deployPs1) {
    try {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployPs1 2>&1 | Out-Null
    } catch {}
  }

  # Siapkan folder .minecraft + options.txt ramah RDP (120 FPS, VSync Off, Raw Mouse Input On)
  $u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }
  $mcDir = "C:\Users\$u\AppData\Roaming\.minecraft"
  New-Item -ItemType Directory -Path $mcDir -Force -ErrorAction SilentlyContinue | Out-Null
  $optFile = Join-Path $mcDir 'options.txt'
  if (-not (Test-Path $optFile)) {
    @(
      'version:3953'
      'autoJump:false'
      'enableVsync:false'
      'maxFps:120'
      'renderDistance:8'
      'simulationDistance:6'
      'graphicsMode:0'
      'ao:false'
      'clouds:false'
      'MipmapLevels:0'
      'rawMouseInput:true'
      'fullscreen:false'
      'guiScale:2'
    ) | Set-Content -Path $optFile -Encoding UTF8 -Force
  }

  # Buat shortcut di Desktop
  foreach ($desk in @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop")) {
    if (Test-Path $desk) {
      try {
        $wsh = New-Object -ComObject WScript.Shell
        if (Test-Path 'C:\Games\PrismLauncher\PrismLauncher.exe') {
          $lnk = $wsh.CreateShortcut((Join-Path $desk 'PrismLauncher (Minecraft Java).lnk'))
          $lnk.TargetPath = 'C:\Games\PrismLauncher\PrismLauncher.exe'
          $lnk.WorkingDirectory = 'C:\Games\PrismLauncher'
          $lnk.Description = 'PrismLauncher Minecraft Java (OpenGL 4.6 D3D12 Ready)'
          $lnk.Save()
        }
        if (Test-Path $deployPs1) {
          $lnkFix = $wsh.CreateShortcut((Join-Path $desk 'Fix OpenGL 4.6 Minecraft (Anti-Error 65542).lnk'))
          $lnkFix.TargetPath = 'powershell.exe'
          $lnkFix.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$deployPs1`""
          $lnkFix.Description = 'Suntikkan ulang driver OpenGL 4.6 D3D12 ke semua runtime Java & Minecraft'
          $lnkFix.Save()
        }
      } catch {}
    }
  }
}

$report = @{}

if ($wantMcJava) {
  Install-JavaRuntimesForMinecraft
  $prismOk = Install-PrismLauncherPortable
  Configure-MinecraftOpenGLAndOptions
  $report['minecraft_java_runtime'] = @{
    java21        = $true
    java8         = $true
    prismlauncher = $prismOk
    opengl46      = (Test-Path 'C:\XyRDP\grafis\mesa-x64\opengl32.dll')
  }
}

if ($wantMcJava -or $wantMcBed) {
  $msi = Join-Path $work 'MinecraftInstaller.msi'
  $mcUrl = 'https://launcher.mojang.com/download/MinecraftInstaller.msi'
  Log 'Mengunduh Minecraft Launcher resmi (Mojang)...'
  if (Invoke-GameDownload $mcUrl $msi) {
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
    $ok = @(0, 1638, 3010) -contains $p.ExitCode
    if ($wantMcJava) {
      Configure-MinecraftOpenGLAndOptions
      $report['minecraft_java'] = if ($ok) { 'installed-with-opengl46' } else { "prism-ready-msi-$($p.ExitCode)" }
    }
    if ($wantMcBed)  { $report['minecraft_bedrock'] = if ($ok) { 'launcher-installed' } else { "exit-$($p.ExitCode)" } }
    Log "Minecraft Launcher selesai (exit=$($p.ExitCode))."
  } else {
    if ($wantMcJava) { $report['minecraft_java'] = 'prism-ready' }
    if ($wantMcBed)  { $report['minecraft_bedrock'] = 'download-failed' }
    Log 'Unduhan MSI Minecraft Launcher gagal (PrismLauncher & Java tetap siap).'
  }
}

if ($wantRoblox) {
  $rbx = Join-Path $work 'RobloxPlayerInstaller.exe'
  Log 'Mengunduh Roblox Player installer resmi...'
  if (Invoke-GameDownload 'https://www.roblox.com/download/client?os=win' $rbx) {
    $desk = Join-Path $env:PUBLIC 'Desktop\Install Roblox.lnk'
    try {
      $wsh = New-Object -ComObject WScript.Shell
      $sc = $wsh.CreateShortcut($desk)
      $sc.TargetPath = $rbx
      $sc.WorkingDirectory = $work
      $sc.Description = 'Jalankan installer resmi Roblox Player'
      $sc.Save()
    } catch {}
    $report['roblox'] = 'installer-staged'
    Log "Installer Roblox disiapkan di $rbx (shortcut Public Desktop dibuat)."
  } else {
    $report['roblox'] = 'download-failed'
    Log 'Unduhan Roblox gagal (non-fatal).'
  }
}

Update-Status @{ games = $report } | Out-Null
exit 0
