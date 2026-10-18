# ============================================================================
#  setup-tools-hub.ps1 — Build & Auto-Install Aplikasi Native GUI Windows:
#                        XyDeskTools.exe ("XyDesk Gaming & Tools Hub")
# ----------------------------------------------------------------------------
#  Menghasilkan executable mandiri C:\XyRDP\tools\XyDeskTools.exe serta
#  menaruhnya langsung di Desktop RDP ("XyDeskTools.exe" & shortcut
#  "XyDesk Gaming & Tools Hub").
#
#  Fitur 1-Klik di dalam XyDeskTools.exe:
#    1) GTA San Andreas & SA-MP / open.mp:
#       - Pasang Runtime Lengkap (DirectPlay + DirectX 9.0c + VC++ 2013/2015-2026)
#       - Patch Folder GTA SA (SilentPatch 90 FPS + ASI Loader + Widescreen + Fix Mouse RDP)
#       - Download & Buka SA-MP / open.mp Client Installer
#       - Atur Nickname SA-MP & Lokasi gta_sa.exe di Registry
#    2) Roblox & Game Modern:
#       - Install / Update Roblox Player + Optimasi Direct3D 11 RDP (Anti White-Screen)
#       - Install Bloxstrap (Roblox FPS Unlocker & FastFlags)
#    3) Minecraft Java & Akselerasi OpenGL 4.6:
#       - Install PrismLauncher Portable + Java 21 LTS & Java 8 LTS
#       - Suntikkan Akselerator OpenGL 4.6 (Mesa3D D3D12) Anti-Error GLFW 65542
#    4) Cloud Save (Login Browser & File) & Sistem RDP:
#       - Simpan Login Browser (Chrome/Google) & File Sekarang (Cloud Save Snapshot)
#       - Pulihkan Simpanan Sesi Sebelumnya (Cloud Restore)
#       - Fix Mouse Gaming RDP + Restart Audio & Mikrofon Virtual
#       - Buka Folder Permanen (C:\Persist) & Folder Game (C:\Games)
# ============================================================================

$ErrorActionPreference = 'Continue'
$XyTag = 'XyRDP:tools-hub'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
$toolsDir = 'C:\XyRDP\tools'
$scriptsSourceDir = 'C:\XyRDP\scripts'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsSourceDir -Force | Out-Null

# Salin seluruh script PowerShell ke C:\XyRDP\scripts agar XyDeskTools.exe bisa memanggilnya kapan saja selama sesi berjalan
try {
  Copy-Item -Path "$PSScriptRoot\*" -Destination $scriptsSourceDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

# Simpan variabel lingkungan penting sesi ke C:\XyRDP\tools\session-env.json supaya Cloud Save manual dari GUI bekerja
try {
  @{
    RDP_USER          = $u
    RDP_PASSWORD      = $env:RDP_PASSWORD
    GITHUB_TOKEN      = $env:GITHUB_TOKEN
    GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
    GITHUB_RUN_ID     = $env:GITHUB_RUN_ID
  } | ConvertTo-Json | Set-Content -Path (Join-Path $toolsDir 'session-env.json') -Encoding UTF8 -Force
} catch {}

$exePath = Join-Path $toolsDir 'XyDeskTools.exe'
Remove-Item $exePath -Force -ErrorAction SilentlyContinue

$csharpSource = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace XyDeskToolsHub
{
    public class MainForm : Form
    {
        private RichTextBox logBox;
        private Label statusLabel;
        private ProgressBar progressBar;
        private TextBox sampNickBox;
        private TextBox sampPathBox;

        public MainForm()
        {
            this.Text = "XyDesk Gaming & Tools Hub v2.0 — SA-MP · Roblox · Minecraft · Cloud Save";
            this.Size = new Size(860, 620);
            this.MinimumSize = new Size(820, 580);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.BackColor = Color.FromArgb(11, 13, 20);
            this.ForeColor = Color.FromArgb(241, 245, 249);
            this.Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);

            BuildUi();
            LoadSampRegistryInfo();
            AppendLog("[READY] XyDesk Gaming & Tools Hub siap digunakan.");
            AppendLog("[INFO] Semua login browser (Chrome/Edge Google), save game, Desktop, Documents, dan C:\\Persist otomatis disimpan lintas sesi.");
        }

        private void BuildUi()
        {
            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 64;
            header.BackColor = Color.FromArgb(18, 22, 34);
            header.Padding = new Padding(18, 10, 18, 10);

            Label title = new Label();
            title.Text = "XyDesk Gaming & Tools Hub";
            title.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
            title.ForeColor = Color.White;
            title.AutoSize = true;
            title.Location = new Point(18, 10);

            Label subtitle = new Label();
            subtitle.Text = "Pusat Installer & Fixer 1-Klik untuk GTA SA-MP, Roblox, Minecraft OpenGL 4.6, Audio/Mouse & Cloud Save Anti-Reset";
            subtitle.Font = new Font("Segoe UI", 9f, FontStyle.Regular);
            subtitle.ForeColor = Color.FromArgb(148, 163, 184);
            subtitle.AutoSize = true;
            subtitle.Location = new Point(20, 37);

            header.Controls.Add(title);
            header.Controls.Add(subtitle);

            Panel footer = new Panel();
            footer.Dock = DockStyle.Bottom;
            footer.Height = 165;
            footer.BackColor = Color.FromArgb(15, 18, 28);
            footer.Padding = new Padding(14, 8, 14, 10);

            statusLabel = new Label();
            statusLabel.Text = "Status: Siap menjalankan perintah.";
            statusLabel.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            statusLabel.ForeColor = Color.FromArgb(56, 189, 248);
            statusLabel.Dock = DockStyle.Top;
            statusLabel.Height = 20;

            progressBar = new ProgressBar();
            progressBar.Dock = DockStyle.Top;
            progressBar.Height = 6;
            progressBar.Style = ProgressBarStyle.Continuous;

            logBox = new RichTextBox();
            logBox.Dock = DockStyle.Fill;
            logBox.BackColor = Color.FromArgb(8, 10, 15);
            logBox.ForeColor = Color.FromArgb(203, 213, 225);
            logBox.BorderStyle = BorderStyle.None;
            logBox.ReadOnly = true;
            logBox.Font = new Font("Consolas", 9f, FontStyle.Regular);

            footer.Controls.Add(logBox);
            footer.Controls.Add(progressBar);
            footer.Controls.Add(statusLabel);

            TabControl tabs = new TabControl();
            tabs.Dock = DockStyle.Fill;
            tabs.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            tabs.Padding = new Point(14, 6);

            TabPage tabSamp = CreateTabPage("GTA SA & SA-MP");
            BuildSampTab(tabSamp);

            TabPage tabRoblox = CreateTabPage("Roblox & Modern Games");
            BuildRobloxTab(tabRoblox);

            TabPage tabMc = CreateTabPage("Minecraft & OpenGL 4.6");
            BuildMinecraftTab(tabMc);

            TabPage tabSystem = CreateTabPage("Cloud Save & Sistem RDP");
            BuildSystemTab(tabSystem);

            tabs.TabPages.Add(tabSamp);
            tabs.TabPages.Add(tabRoblox);
            tabs.TabPages.Add(tabMc);
            tabs.TabPages.Add(tabSystem);

            this.Controls.Add(tabs);
            this.Controls.Add(footer);
            this.Controls.Add(header);
        }

        private TabPage CreateTabPage(string text)
        {
            TabPage page = new TabPage(text);
            page.BackColor = Color.FromArgb(14, 17, 26);
            page.ForeColor = Color.White;
            page.Padding = new Padding(16);
            return page;
        }

        private Button CreateActionButton(string title, string desc, Color accent, int x, int y, int w, int h, EventHandler onClick)
        {
            Button btn = new Button();
            btn.Text = title + "\n" + desc;
            btn.Location = new Point(x, y);
            btn.Size = new Size(w, h);
            btn.FlatStyle = FlatStyle.Flat;
            btn.FlatAppearance.BorderColor = accent;
            btn.FlatAppearance.BorderSize = 1;
            btn.BackColor = Color.FromArgb(22, 27, 40);
            btn.ForeColor = Color.White;
            btn.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            btn.TextAlign = ContentAlignment.MiddleLeft;
            btn.Padding = new Padding(12, 0, 10, 0);
            btn.Cursor = Cursors.Hand;
            btn.Click += onClick;
            return btn;
        }

        private void BuildSampTab(TabPage page)
        {
            int w = 385, h = 68;
            page.Controls.Add(CreateActionButton(
                "1. Pasang Runtime SA-MP Lengkap (DirectX 9 + DirectPlay + VC++)",
                "Wajib agar GTA SA & SA-MP tidak crash / tidak minta d3dx9_43.dll",
                Color.FromArgb(99, 102, 241), 16, 14, w, h,
                (s, e) => RunPowerShellTask("Memasang Runtime DirectX 9 + DirectPlay + VC++...", @"& 'C:\XyRDP\scripts\setup-samp.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Patch Folder GTA SA (SilentPatch 90 FPS + Fix Mouse RDP)",
                "Pasang ASI Loader, SilentPatch, Widescreen & Fix Mouse Stuck di RDP",
                Color.FromArgb(16, 185, 129), 416, 14, w, h,
                (s, e) => RunPowerShellTask("Memilih & mem-patch folder GTA San Andreas...", @"& 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1' -Interactive")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Download & Buka Installer SA-MP / open.mp Client",
                "Unduh otomatis SA-MP 0.3.7 & open.mp Launcher di C:\\Games\\GTA-SAMP",
                Color.FromArgb(245, 158, 11), 16, 94, w, h,
                (s, e) => RunPowerShellTask("Menyiapkan SA-MP / open.mp Client...", @"
                    New-Item -ItemType Directory -Path 'C:\Games\GTA-SAMP\Installers' -Force | Out-Null
                    $omp = 'C:\Games\GTA-SAMP\Installers\omp-launcher-setup.exe'
                    if (-not (Test-Path $omp)) {
                        & curl.exe -fL --retry 2 -sS 'https://github.com/openmultiplayer/launcher/releases/latest/download/omp-launcher-setup.exe' -o $omp
                    }
                    if (Test-Path $omp) { Start-Process $omp }
                    Start-Process explorer.exe 'C:\Games\GTA-SAMP'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder GTA-SAMP & Folder Permanen (C:\\Persist)",
                "Taruh file GTA SA kamu di C:\\Games atau C:\\Persist agar anti-reset",
                Color.FromArgb(56, 189, 248), 416, 94, w, h,
                (s, e) => {
                    Directory.CreateDirectory(@"C:\Games");
                    Directory.CreateDirectory(@"C:\Persist");
                    Process.Start("explorer.exe", @"C:\Games");
                }
            ));

            Panel regPanel = new Panel();
            regPanel.Location = new Point(16, 178);
            regPanel.Size = new Size(785, 115);
            regPanel.BackColor = Color.FromArgb(20, 24, 36);
            regPanel.Padding = new Padding(12);

            Label lblNick = new Label { Text = "Nickname SA-MP:", Location = new Point(14, 16), AutoSize = true, ForeColor = Color.FromArgb(203, 213, 225) };
            sampNickBox = new TextBox { Location = new Point(140, 13), Width = 220, BackColor = Color.FromArgb(12, 15, 23), ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };

            Label lblPath = new Label { Text = "Lokasi gta_sa.exe:", Location = new Point(14, 50), AutoSize = true, ForeColor = Color.FromArgb(203, 213, 225) };
            sampPathBox = new TextBox { Location = new Point(140, 47), Width = 430, BackColor = Color.FromArgb(12, 15, 23), ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };

            Button btnBrowse = new Button { Text = "Pilih gta_sa.exe...", Location = new Point(580, 45), Size = new Size(185, 27), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(30, 41, 59), ForeColor = Color.White };
            btnBrowse.Click += (s, e) => {
                OpenFileDialog ofd = new OpenFileDialog();
                ofd.Filter = "gta_sa.exe|gta_sa.exe|Executable (*.exe)|*.exe";
                if (ofd.ShowDialog() == DialogResult.OK) sampPathBox.Text = ofd.FileName;
            };

            Button btnSaveSamp = new Button { Text = "Simpan ke Registry SA-MP", Location = new Point(375, 11), Size = new Size(195, 28), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(16, 185, 129), ForeColor = Color.Black, Font = new Font("Segoe UI", 9f, FontStyle.Bold) };
            btnSaveSamp.Click += (s, e) => SaveSampRegistryInfo();

            Label lblHint = new Label { Text = "Tip: Pengaturan Nickname & path gta_sa.exe di atas otomatis tersimpan lintas sesi RDP.", Location = new Point(14, 84), AutoSize = true, ForeColor = Color.FromArgb(148, 163, 184) };

            regPanel.Controls.AddRange(new Control[] { lblNick, sampNickBox, btnSaveSamp, lblPath, sampPathBox, btnBrowse, lblHint });
            page.Controls.Add(regPanel);
        }

        private void BuildRobloxTab(TabPage page)
        {
            int w = 385, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Install / Update Roblox Player Resmi",
                "Unduh & pasang Roblox Player terbaru + buat shortcut di Desktop",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Mengunduh & memasang Roblox Player...", @"$env:ROBLOX='ya'; & 'C:\XyRDP\scripts\setup-games.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Fix Grafik Roblox di RDP (Direct3D 11 + Anti White-Screen)",
                "Terapkan ClientAppSettings DX11 + matikan Fullscreen Optimization + WebView2",
                Color.FromArgb(99, 102, 241), 416, 16, w, h,
                (s, e) => RunPowerShellTask("Menerapkan optimasi grafik Direct3D 11 untuk Roblox...", @"
                    & 'C:\XyRDP\scripts\setup-grafis.ps1'
                    $rbxVer = Join-Path $env:LOCALAPPDATA 'Roblox\Versions'
                    if (Test-Path $rbxVer) {
                        Get-ChildItem -Path $rbxVer -Directory | ForEach-Object {
                            $csDir = Join-Path $_.FullName 'ClientSettings'
                            New-Item -ItemType Directory -Path $csDir -Force | Out-Null
                            @{
                                FFlagDebugGraphicsPreferD3D11 = $true
                                FFlagDebugGraphicsDisableDirect3D11 = $false
                                DFIntTaskSchedulerTargetFps = 120
                                FFlagHandleAltEnterFullscreenManually = $false
                            } | ConvertTo-Json | Set-Content (Join-Path $csDir 'ClientAppSettings.json') -Encoding UTF8 -Force
                        }
                    }
                    Write-Host 'Optimasi Direct3D 11 & 120 FPS Roblox selesai diterapkan!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Install Bloxstrap (Launcher Mod Roblox + FastFlags + FPS)",
                "Pasang Bloxstrap terbaru untuk atur wilayah server, ping & grafik ringan",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Mengunduh & menjalankan Bloxstrap...", @"
                    $work = 'C:\XyRDP\deps\games'
                    New-Item -ItemType Directory -Path $work -Force | Out-Null
                    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/bloxstraplabs/bloxstrap/releases/latest' -Headers @{ 'User-Agent' = 'XyRDP' }
                    $asset = $rel.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
                    if ($asset) {
                        $exe = Join-Path $work $asset.name
                        & curl.exe -fL --retry 2 -sS $asset.browser_download_url -o $exe
                        if (Test-Path $exe) { Start-Process $exe }
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Pasang Runtime All-in-One Game (WebView2 + VC++ + DX9)",
                "Perbaiki error DLL hilang (VCRUNTIME140.dll / XINPUT1_3.dll / WebView2)",
                Color.FromArgb(56, 189, 248), 416, 106, w, h,
                (s, e) => RunPowerShellTask("Memeriksa & memasang seluruh runtime game...", @"& 'C:\XyRDP\scripts\setup-samp.ps1'")
            ));
        }

        private void BuildMinecraftTab(TabPage page)
        {
            int w = 385, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Install Minecraft Java (PrismLauncher + JDK 21 & JRE 8)",
                "Pasang PrismLauncher Portable di C:\\Games\\PrismLauncher + Java 21 & 8",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Memasang PrismLauncher + Java 21 + Java 8...", @"$env:MINECRAFT_JAVA='ya'; & 'C:\XyRDP\scripts\setup-games.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Suntikkan Akselerator OpenGL 4.6 (Mesa3D D3D12)",
                "Atasi error 'GLFW error 65542: The driver does not appear to support OpenGL'",
                Color.FromArgb(99, 102, 241), 416, 16, w, h,
                (s, e) => RunPowerShellTask("Menyuntikkan Mesa3D OpenGL 4.6 ke semua runtime Java...", @"
                    $env:GRAFIS='software'
                    & 'C:\XyRDP\scripts\setup-grafis.ps1'
                    if (Test-Path 'C:\XyRDP\grafis\Deploy-OpenGL-To-Java.ps1') {
                        & 'C:\XyRDP\grafis\Deploy-OpenGL-To-Java.ps1'
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Install Official Minecraft Launcher (Bedrock & Java)",
                "Unduh & pasang MinecraftInstaller.exe resmi dari Xbox/Mojang",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Memasang Official Minecraft Launcher...", @"$env:MINECRAFT_BEDROCK='ya'; & 'C:\XyRDP\scripts\setup-games.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder .minecraft & PrismLauncher",
                "Akses cepat ke folder mods, resourcepacks, dan world saves",
                Color.FromArgb(56, 189, 248), 416, 106, w, h,
                (s, e) => {
                    string mc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), ".minecraft");
                    Directory.CreateDirectory(mc);
                    Process.Start("explorer.exe", mc);
                }
            ));
        }

        private void BuildSystemTab(TabPage page)
        {
            int w = 385, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Simpan Login Browser & Data Sekarang (Cloud Save)",
                "Backup instan login Google/Chrome, save game, Desktop & C:\\Persist ke Cloud",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Menyimpan snapshot Login Browser + Game + File ke Cloud...", @"
                    if (Test-Path 'C:\XyRDP\tools\session-env.json') {
                        $j = Get-Content 'C:\XyRDP\tools\session-env.json' -Raw | ConvertFrom-Json
                        if ($j.RDP_USER) { $env:RDP_USER = $j.RDP_USER }
                        if ($j.RDP_PASSWORD) { $env:RDP_PASSWORD = $j.RDP_PASSWORD }
                        if ($j.GITHUB_TOKEN) { $env:GITHUB_TOKEN = $j.GITHUB_TOKEN }
                        if ($j.GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY = $j.GITHUB_REPOSITORY }
                        if ($j.GITHUB_RUN_ID) { $env:GITHUB_RUN_ID = $j.GITHUB_RUN_ID }
                    }
                    & 'C:\XyRDP\scripts\persist-state.ps1' -Checkpoint
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Pulihkan Simpanan Sesi Sebelumnya (Cloud Restore)",
                "Tarik ulang simpanan terbaru dari Release 'xyrdp-state-latest'",
                Color.FromArgb(99, 102, 241), 416, 16, w, h,
                (s, e) => RunPowerShellTask("Memulihkan state dari Cloud...", @"
                    if (Test-Path 'C:\XyRDP\tools\session-env.json') {
                        $j = Get-Content 'C:\XyRDP\tools\session-env.json' -Raw | ConvertFrom-Json
                        if ($j.RDP_USER) { $env:RDP_USER = $j.RDP_USER }
                        if ($j.RDP_PASSWORD) { $env:RDP_PASSWORD = $j.RDP_PASSWORD }
                        if ($j.GITHUB_TOKEN) { $env:GITHUB_TOKEN = $j.GITHUB_TOKEN }
                        if ($j.GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY = $j.GITHUB_REPOSITORY }
                    }
                    & 'C:\XyRDP\scripts\restore-state.ps1'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Fix Mouse Gaming RDP & Restart Audio / Mikrofon",
                "Matikan akselerasi mouse yang bikin kamera muter + segarkan Windows Audio",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Mengoptimalkan Mouse Gaming & merestart layanan Audio RDP...", @"
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -ErrorAction SilentlyContinue
                    Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
                    Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
                    Write-Host 'Mouse Gaming (Raw Input) & Audio/Mic RDP berhasil dioptimalkan!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Bersihkan RAM & Sampah Temp (FPS Booster)",
                "Kosongkan file temp & segarkan memori agar game jalan lebih enteng",
                Color.FromArgb(56, 189, 248), 416, 106, w, h,
                (s, e) => RunPowerShellTask("Membersihkan cache sementara & mengoptimalkan memori...", @"
                    Remove-Item -Path ""$env:TEMP\*"" -Recurse -Force -ErrorAction SilentlyContinue
                    [System.GC]::Collect()
                    Write-Host 'Pembersihan Temp & optimasi RAM selesai!'
                ")
            ));
        }

        private void LoadSampRegistryInfo()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\SAMP", false))
                {
                    if (key != null)
                    {
                        sampNickBox.Text = Convert.ToString(key.GetValue("PlayerName", Environment.UserName));
                        sampPathBox.Text = Convert.ToString(key.GetValue("gta_sa_exe", @"C:\Games\GTA San Andreas\gta_sa.exe"));
                        return;
                    }
                }
            }
            catch { }
            sampNickBox.Text = Environment.UserName;
            sampPathBox.Text = @"C:\Games\GTA San Andreas\gta_sa.exe";
        }

        private void SaveSampRegistryInfo()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\SAMP"))
                {
                    key.SetValue("PlayerName", sampNickBox.Text.Trim());
                    key.SetValue("gta_sa_exe", sampPathBox.Text.Trim());
                }
                AppendLog("[OK] Registry HKCU\\Software\\SAMP berhasil disimpan: Nick=" + sampNickBox.Text.Trim());
                statusLabel.Text = "Status: Pengaturan SA-MP tersimpan.";
            }
            catch (Exception ex)
            {
                AppendLog("[ERR] Gagal menyimpan registry SA-MP: " + ex.Message);
            }
        }

        private void AppendLog(string line)
        {
            if (this.InvokeRequired)
            {
                this.BeginInvoke(new Action<string>(AppendLog), line);
                return;
            }
            logBox.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line + Environment.NewLine);
            logBox.SelectionStart = logBox.Text.Length;
            logBox.ScrollToCaret();
        }

        private void RunPowerShellTask(string label, string psCommand)
        {
            statusLabel.Text = "Status: " + label;
            progressBar.Style = ProgressBarStyle.Marquee;
            AppendLog("==> " + label);

            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    string tempScript = Path.Combine(Path.GetTempPath(), "xydesk_task_" + Guid.NewGuid().ToString("N") + ".ps1");
                    File.WriteAllText(tempScript, psCommand, System.Text.Encoding.UTF8);

                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = "powershell.exe";
                    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempScript + "\"";
                    psi.UseShellExecute = false;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    psi.CreateNoWindow = true;

                    using (Process proc = Process.Start(psi))
                    {
                        proc.OutputDataReceived += (s, ev) => { if (!string.IsNullOrEmpty(ev.Data)) AppendLog(ev.Data); };
                        proc.ErrorDataReceived += (s, ev) => { if (!string.IsNullOrEmpty(ev.Data)) AppendLog("[WARN] " + ev.Data); };
                        proc.BeginOutputReadLine();
                        proc.BeginErrorReadLine();
                        proc.WaitForExit();
                    }
                    try { File.Delete(tempScript); } catch { }

                    this.BeginInvoke(new Action(() =>
                    {
                        progressBar.Style = ProgressBarStyle.Continuous;
                        progressBar.Value = 100;
                        statusLabel.Text = "Status: Selesai — " + label;
                        AppendLog("[SELESAI] " + label);
                    }));
                }
                catch (Exception ex)
                {
                    this.BeginInvoke(new Action(() =>
                    {
                        progressBar.Style = ProgressBarStyle.Continuous;
                        progressBar.Value = 0;
                        statusLabel.Text = "Status: Gagal (" + ex.Message + ")";
                        AppendLog("[ERROR] " + ex.Message);
                    }));
                }
            });
        }

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
'@

try {
  Add-Type -TypeDefinition $csharpSource `
    -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll') `
    -OutputAssembly $exePath `
    -OutputType WindowsApplication `
    -ErrorAction Stop

  if (Test-Path $exePath) {
    Log "XyDeskTools.exe berhasil dikompilasi di $exePath"
    foreach ($desk in @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop")) {
      if (-not (Test-Path $desk)) {
        New-Item -ItemType Directory -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
      }
      try {
        # Taruh file .exe langsung di Desktop user RDP DAN buat shortcut dengan ikon game/tools
        Copy-Item -Path $exePath -Destination (Join-Path $desk 'XyDeskTools.exe') -Force -ErrorAction SilentlyContinue
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $desk 'XyDesk Gaming & Tools Hub.lnk'))
        $lnk.TargetPath = $exePath
        $lnk.WorkingDirectory = $toolsDir
        $lnk.Description = 'Pusat Installer & Fixer 1-Klik SA-MP, Roblox, Minecraft & Cloud Save'
        $lnk.IconLocation = 'shell32.dll,21'
        $lnk.Save()
      } catch {}
    }
    Update-Status @{ tools_hub = @{ installed = $true; exe = $exePath } } | Out-Null
  }
} catch {
  Log "Kompilasi XyDeskTools.exe warning: $($_.Exception.Message)"
}
exit 0
