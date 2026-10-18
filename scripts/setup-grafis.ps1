# ============================================================================
#  setup-grafis.ps1 — Akselerasi OpenGL 4.6 (Mesa3D D3D12 / Gallium) untuk
#                     Minecraft Java & Aplikasi 3D di Windows Server RDP
# ----------------------------------------------------------------------------
#  1) Mengekstrak Mesa3D ke C:\XyRDP\grafis\mesa-x64 (tanpa menimpa System32
#     agar komponen sistem Windows tetap aman).
#  2) Mengatur variabel lingkungan GALLIUM_DRIVER=d3d12 & MESA_GL_VERSION_OVERRIDE=4.6
#     agar OpenGL 4.6 diterjemahkan ke Direct3D 12 multithreaded (anti-GLFW 65542).
#  3) Menyediakan script Deploy-OpenGL-To-Java.ps1 yang otomatis menyalin
#     opengl32.dll + libgallium_wgl.dll + libglapi.dll ke folder bin/ Java &
#     Minecraft Launcher supaya Minecraft Java langsung jalan tanpa error driver!
# ============================================================================

$XyTag = 'XyRDP:grafis'
. "$PSScriptRoot/lib-common.ps1"

$mode = if ($env:GRAFIS) { $env:GRAFIS.Trim().ToLower() } else { 'software' }
if (@('tidak','0','false','no','off','skip','none') -contains $mode) {
  Log 'setup grafis dilewati (input grafis=tidak)'
  Update-Status @{ grafis = @{ mode = 'native' } } | Out-Null
  exit 0
}

$work = 'C:\XyRDP\grafis'
$mesaDir = Join-Path $work 'mesa-x64'
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $mesaDir -Force | Out-Null

try {
  $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/pal1000/mesa-dist-win/releases/latest' `
    -Headers @{ 'User-Agent' = 'XyRDP' } -TimeoutSec 20
  $asset = $rel.assets | Where-Object { $_.name -match 'release-msvc' -and $_.name -match '\.(7z|zip)$' } | Select-Object -First 1
  if ($asset) {
    $arc = Join-Path $work $asset.name
    Log "Unduh Mesa3D ($($asset.name))..."
    & curl.exe -fL --retry 3 --connect-timeout 20 -sS $asset.browser_download_url -o $arc
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
    $ext = Join-Path $work 'mesa-extract'
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $ext -Force | Out-Null
    if (Test-Path $sevenZip) {
      & $sevenZip x $arc "-o$ext" -y | Out-Null
      # Ekstrak arsip bertingkat (.7z di dalam .7z) bila ada
      Get-ChildItem -Path $ext -Recurse -File -Include '*.7z','*.zip' -ErrorAction SilentlyContinue | ForEach-Object {
        & $sevenZip x $_.FullName "-o$ext" -y | Out-Null
      }
    }

    # Salin DLL x64 (opengl32.dll, libgallium_wgl.dll, libglapi.dll, dxil.dll, zink/d3d12) ke C:\XyRDP\grafis\mesa-x64
    $x64Dir = Get-ChildItem -Path $ext -Recurse -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ieq 'x64' -and (Test-Path (Join-Path $_.FullName 'opengl32.dll')) } |
      Select-Object -First 1
    if ($x64Dir) {
      Copy-Item -Path "$($x64Dir.FullName)\*.dll" -Destination $mesaDir -Force -ErrorAction SilentlyContinue
    } else {
      Get-ChildItem -Path $ext -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'x86|win32' } |
        ForEach-Object { Copy-Item $_.FullName -Destination (Join-Path $mesaDir $_.Name) -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue

    # Set environment variable OpenGL 4.6 di atas D3D12 (aman untuk sistem Windows, hanya dibaca Mesa)
    $envKey = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    Set-Reg $envKey 'GALLIUM_DRIVER'           'd3d12' 'String' | Out-Null
    Set-Reg $envKey 'MESA_GL_VERSION_OVERRIDE' '4.6'   'String' | Out-Null
    Set-Reg $envKey 'MESA_GLSL_VERSION_OVERRIDE' '460' 'String' | Out-Null
    $env:GALLIUM_DRIVER = 'd3d12'
    $env:MESA_GL_VERSION_OVERRIDE = '4.6'
    $env:MESA_GLSL_VERSION_OVERRIDE = '460'

    # Buat script helper Deploy-OpenGL-To-Java.ps1 untuk menyuntikkan OpenGL 4.6 ke Java & Minecraft
    $deployPs1 = Join-Path $work 'Deploy-OpenGL-To-Java.ps1'
    $deployCode = @'
$ErrorActionPreference = 'Continue'
$mesaDir = 'C:\XyRDP\grafis\mesa-x64'
if (-not (Test-Path (Join-Path $mesaDir 'opengl32.dll'))) { exit 0 }

$targets = New-Object System.Collections.Generic.List[string]
foreach ($root in @(
  'C:\Program Files\Eclipse Adoptium',
  'C:\Program Files\Java',
  'C:\Program Files\Microsoft',
  'C:\Program Files (x86)\Minecraft Launcher\runtime',
  'C:\Games\PrismLauncher',
  'C:\Persist'
)) {
  if (Test-Path $root) {
    Get-ChildItem -Path $root -Recurse -File -Include 'javaw.exe','java.exe','PrismLauncher.exe' -ErrorAction SilentlyContinue | ForEach-Object {
      $dir = $_.DirectoryName
      if (-not $targets.Contains($dir)) { $targets.Add($dir) }
    }
  }
}

Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  foreach ($sub in @('AppData\Roaming\.minecraft\runtime','AppData\Roaming\PrismLauncher\java','AppData\Roaming\.tlauncher\jvms','AppData\Local\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime')) {
    $p = Join-Path $_.FullName $sub
    if (Test-Path $p) {
      Get-ChildItem -Path $p -Recurse -File -Include 'javaw.exe','java.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_.DirectoryName
        if (-not $targets.Contains($dir)) { $targets.Add($dir) }
      }
    }
  }
}

foreach ($dir in $targets) {
  Copy-Item -Path "$mesaDir\*.dll" -Destination $dir -Force -ErrorAction SilentlyContinue
  Write-Host "OpenGL 4.6 (Mesa D3D12) diaktifkan untuk: $dir"
}
'@
    Set-Content -Path $deployPs1 -Value $deployCode -Encoding UTF8 -Force
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployPs1 2>&1 | Out-Null

    Log "Mesa3D OpenGL 4.6 (D3D12 backend) siap di $mesaDir"
    Update-Status @{ grafis = @{ mode = 'mesa-d3d12-opengl46'; path = $mesaDir } } | Out-Null
    exit 0
  }
} catch {
  Log "setup grafis gagal (non-fatal): $($_.Exception.Message)"
}
Update-Status @{ grafis = @{ mode = 'native-fallback' } } | Out-Null
exit 0
