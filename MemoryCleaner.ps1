# MemoryCleaner.ps1 - Windows 内存清理小工具（图形界面）
# 原理：调用 EmptyWorkingSet 将各进程的工作集（物理内存页）裁剪回页面文件，
#       这是 Mem Reduct 等内存清理工具的标准做法，安全、可逆。
# 托盘：自定义内存芯片图标，实时显示使用率数字（颜色随占用由冷色渐变到暖色），悬停可见详情。
# 使用：双击同目录下的 MemoryCleaner.bat，或：
#       powershell -NoProfile -ExecutionPolicy Bypass -File MemoryCleaner.ps1
# 参数：-Test      自检模式（只验证编译与内存读取，不显示界面）
#       -Minimized 启动后直接最小化到系统托盘（配合开机自启使用）
#Requires -Version 5.1
param(
    [switch]$Test,
    [switch]$Minimized
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- P/Invoke：内存状态读取 + 工作集裁剪 ----------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public static class NativeMem
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private class MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

    public static uint LoadPercent;
    public static ulong TotalPhys;
    public static ulong AvailPhys;

    public static void Refresh()
    {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        if (GlobalMemoryStatusEx(m))
        {
            LoadPercent = m.dwMemoryLoad;
            TotalPhys = m.ullTotalPhys;
            AvailPhys = m.ullAvailPhys;
        }
    }

    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint PROCESS_SET_QUOTA        = 0x0100;

    [DllImport("kernel32.dll")]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("psapi.dll")]
    private static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);

    /// <summary>裁剪当前会话进程的工作集，返回成功裁剪的进程数。</summary>
    public static int TrimWorkingSets()
    {
        int count = 0;
        int mySession = Process.GetCurrentProcess().SessionId;
        foreach (Process p in Process.GetProcesses())
        {
            try
            {
                if (p.SessionId != mySession) continue; // 只处理当前会话，普通权限即可，避免动到系统服务
                IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, false, (uint)p.Id);
                if (h != IntPtr.Zero)
                {
                    if (EmptyWorkingSet(h)) count++;
                    CloseHandle(h);
                }
            }
            catch { }
        }
        return count;
    }
}
'@

# ---------- 占用颜色：冷色 → 暖色平滑渐变（偏亮色系） ----------
function Get-MemColor {
    param([int]$Percent)
    # 渐变锚点（偏亮）：冷蓝 → 青 → 黄橙 → 暖红
    $stops = @(
        @{ P = 0;   R = 107; G = 163; B = 243 },
        @{ P = 35;  R = 99;  G = 211; B = 227 },
        @{ P = 65;  R = 247; G = 203; B = 99  },
        @{ P = 100; R = 239; G = 107; B = 99  }
    )
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    for ($i = 0; $i -lt $stops.Count - 1; $i++) {
        if ($p -le $stops[$i + 1].P) {
            $a = $stops[$i]
            $b = $stops[$i + 1]
            $t = ($p - $a.P) / ($b.P - $a.P)
            $r = [Math]::Round($a.R + ($b.R - $a.R) * $t)
            $g = [Math]::Round($a.G + ($b.G - $a.G) * $t)
            $bl = [Math]::Round($a.B + ($b.B - $a.B) * $t)
            return [System.Drawing.Color]::FromArgb(255, $r, $g, $bl)
        }
    }
    return [System.Drawing.Color]::FromArgb(255, 239, 107, 99)
}

# ---------- 颜色明暗辅助 ----------
function Adjust-Color {
    param(
        [System.Drawing.Color]$Color,
        [double]$Brightness   # 正数变亮、负数变暗（0~1）
    )
    if ($Brightness -ge 0) {
        $r = [Math]::Min(255, [int]($Color.R + (255 - $Color.R) * $Brightness))
        $g = [Math]::Min(255, [int]($Color.G + (255 - $Color.G) * $Brightness))
        $b = [Math]::Min(255, [int]($Color.B + (255 - $Color.B) * $Brightness))
    } else {
        $f = 1 + $Brightness
        $r = [int]($Color.R * $f)
        $g = [int]($Color.G * $f)
        $b = [int]($Color.B * $f)
    }
    return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

# ---------- 圆角矩形路径 ----------
function New-RoundedRectPath {
    param(
        [double]$X, [double]$Y, [double]$W, [double]$H, [double]$R
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# ---------- 图标绘制（精致圆角方形 + 玻璃光泽 + 使用率数字，随占用变色） ----------
function New-MemIcon {
    param(
        [int]$Percent = -1,
        [switch]$NoText
    )
    # 32x32 绘制：圆角方形渐变底 + 顶部高光带（玻璃光泽）+ 细边框，再缩放到 16x16（托盘尺寸）
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    if ($Percent -lt 0) { $base = [System.Drawing.Color]::FromArgb(255, 82, 130, 180) }   # 中性：钢蓝
    else { $base = Get-MemColor $Percent }                                                 # 冷→暖渐变

    # 圆角方形主体（垂直渐变：顶部亮 15%、底部暗 20%）
    $light = Adjust-Color $base 0.15
    $dark = Adjust-Color $base -0.20
    $bodyRect = New-Object System.Drawing.RectangleF(2, 2, 28, 28)
    $bodyPath = New-RoundedRectPath 2 2 28 28 7
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $bodyRect, $light, $dark, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($grad, $bodyPath)
    $grad.Dispose()

    # 顶部高光带（玻璃光泽：Clip 到圆角矩形内，画半透明白色大椭圆）
    $g.SetClip($bodyPath)
    $hiBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
    $g.FillEllipse($hiBrush, -2, -8, 36, 22)
    $hiBrush.Dispose()
    $g.ResetClip()

    # 细边框（比主色略深的半透明描边，增强轮廓）
    $borderPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(200, (Adjust-Color $base -0.25)), 1.0)
    $g.DrawPath($borderPen, (New-RoundedRectPath 2.5 2.5 27 27 6.5))
    $borderPen.Dispose()
    $bodyPath.Dispose()

    # 缩放到 16x16
    $small = New-Object System.Drawing.Bitmap(16, 16)
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, 16, 16)

    # 在 16x16 上直接画使用率数字（纯白 + 1px 黑色描边，高对比度；SingleBit 渲染，2位10.5px、3位7.75px）
    if (-not $NoText -and $Percent -ge 0) {
        $fontSize = if ($Percent -ge 100) { 7.75 } else { 10.5 }
        $font = New-Object System.Drawing.Font('Arial', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(0, 0, 16, 16)
        $g2.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
        # 先画 8 方向偏移的黑色文字，形成 1px 描边
        $darkBrush = [System.Drawing.Brushes]::Black
        foreach ($d in @(@(-1, 0), @(1, 0), @(0, -1), @(0, 1), @(-1, -1), @(1, 1), @(-1, 1), @(1, -1))) {
            $r2 = New-Object System.Drawing.RectangleF($d[0], $d[1], 16, 16)
            $g2.DrawString([string]$Percent, $font, $darkBrush, $r2, $fmt)
        }
        # 再画白色本体
        $g2.DrawString([string]$Percent, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
        $font.Dispose()
        $fmt.Dispose()
    }

    # Clone 出独立句柄的 Icon，再销毁原始 HICON，避免 GDI 泄漏
    $hIcon = $small.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon).Clone()
    [void][NativeMem]::DestroyIcon($hIcon)

    $g2.Dispose()
    $small.Dispose()
    $g.Dispose()
    $bmp.Dispose()
    return $icon
}

# ---------- 自检模式 ----------
if ($Test) {
    [NativeMem]::Refresh()
    $totalGB = [Math]::Round([NativeMem]::TotalPhys / 1GB, 2)
    $availGB = [Math]::Round([NativeMem]::AvailPhys / 1GB, 2)
    Write-Output ("OK 总内存={0}GB 可用={1}GB 使用率={2}%" -f $totalGB, $availGB, [NativeMem]::LoadPercent)
    # 渲染图标预览图（5 档渐变状态）供人工检查
    $preview = New-Object System.Drawing.Bitmap(420, 100)
    $pg = [System.Drawing.Graphics]::FromImage($preview)
    $pg.Clear([System.Drawing.Color]::White)
    $previewIcons = @()
    $previewIcons += New-MemIcon -Percent 0
    $previewIcons += New-MemIcon -Percent 25
    $previewIcons += New-MemIcon -Percent 50
    $previewIcons += New-MemIcon -Percent 75
    $previewIcons += New-MemIcon -Percent 100
    $x = 10
    foreach ($ic in $previewIcons) {
        $bmp16 = $ic.ToBitmap()
        $pg.DrawImage($bmp16, $x, 10, 64, 64)
        $bmp16.Dispose()
        $ic.Dispose()
        $x += 80
    }
    $pg.Dispose()
    $preview.Save((Join-Path $PSScriptRoot 'MemoryCleaner_icon_preview.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $preview.Dispose()
    exit 0
}

# ---------- 单实例保护 ----------
$mutex = New-Object System.Threading.Mutex($false, 'MemoryCleanerTool_OneInstance')
if (-not $mutex.WaitOne(0, $false)) {
    # 程序已在运行：若不是开机自启场景（-Minimized），通知已有实例弹出主界面
    if (-not $Minimized) {
        try {
            $showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'MemoryCleanerShowEvent')
            [void]$showEvent.Set()
            $showEvent.Dispose()
        } catch { }
    }
    exit 0
}

# ---------- 界面控件 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '内存清理工具'
$form.ClientSize = New-Object System.Drawing.Size(580, 620)
$form.MinimumSize = New-Object System.Drawing.Size(580, 620)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Icon = New-MemIcon -Percent -1 -NoText

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = '内存清理工具'
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(16, 10)
$titleLabel.Size = New-Object System.Drawing.Size(180, 32)
$form.Controls.Add($titleLabel)

$pctLabel = New-Object System.Windows.Forms.Label
$pctLabel.Text = '0 %'
$pctLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$pctLabel.ForeColor = [System.Drawing.Color]::SeaGreen
$pctLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$pctLabel.Location = New-Object System.Drawing.Point(200, 8)
$pctLabel.Size = New-Object System.Drawing.Size(90, 36)
$form.Controls.Add($pctLabel)

$memLabel = New-Object System.Windows.Forms.Label
$memLabel.Text = '正在读取内存信息...'
$memLabel.Location = New-Object System.Drawing.Point(300, 18)
$memLabel.Size = New-Object System.Drawing.Size(270, 20)
$form.Controls.Add($memLabel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(16, 52)
$bar.Size = New-Object System.Drawing.Size(548, 18)
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$form.Controls.Add($bar)

$procList = New-Object System.Windows.Forms.ListView
$procList.Location = New-Object System.Drawing.Point(16, 80)
$procList.Size = New-Object System.Drawing.Size(548, 336)
$procList.View = [System.Windows.Forms.View]::Details
$procList.FullRowSelect = $true
$procList.GridLines = $true
$procList.HideSelection = $false
$procList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$procList.Columns.Add('进程', 220)
[void]$procList.Columns.Add('PID', 70)
[void]$procList.Columns.Add('内存 (MB)', 110)
$form.Controls.Add($procList)

$autoCleanCheck = New-Object System.Windows.Forms.CheckBox
$autoCleanCheck.Text = '自动清理'
$autoCleanCheck.Location = New-Object System.Drawing.Point(16, 428)
$autoCleanCheck.Size = New-Object System.Drawing.Size(130, 22)
$form.Controls.Add($autoCleanCheck)

$lbl1 = New-Object System.Windows.Forms.Label
$lbl1.Text = '内存占用超过'
$lbl1.Location = New-Object System.Drawing.Point(152, 430)
$lbl1.Size = New-Object System.Drawing.Size(85, 20)
$form.Controls.Add($lbl1)

$thresholdBox = New-Object System.Windows.Forms.NumericUpDown
$thresholdBox.Location = New-Object System.Drawing.Point(240, 428)
$thresholdBox.Size = New-Object System.Drawing.Size(55, 24)
$thresholdBox.Minimum = 50
$thresholdBox.Maximum = 95
$thresholdBox.Value = 75
$form.Controls.Add($thresholdBox)

$lbl2 = New-Object System.Windows.Forms.Label
$lbl2.Text = '% 时触发'
$lbl2.Location = New-Object System.Drawing.Point(300, 430)
$lbl2.Size = New-Object System.Drawing.Size(70, 20)
$form.Controls.Add($lbl2)

$periodicCheck = New-Object System.Windows.Forms.CheckBox
$periodicCheck.Text = '定时清理'
$periodicCheck.Location = New-Object System.Drawing.Point(16, 458)
$periodicCheck.Size = New-Object System.Drawing.Size(130, 22)
$form.Controls.Add($periodicCheck)

$lbl3 = New-Object System.Windows.Forms.Label
$lbl3.Text = '每'
$lbl3.Location = New-Object System.Drawing.Point(152, 460)
$lbl3.Size = New-Object System.Drawing.Size(25, 20)
$form.Controls.Add($lbl3)

$intervalBox = New-Object System.Windows.Forms.NumericUpDown
$intervalBox.Location = New-Object System.Drawing.Point(178, 458)
$intervalBox.Size = New-Object System.Drawing.Size(55, 24)
$intervalBox.Minimum = 1
$intervalBox.Maximum = 1440
$intervalBox.Value = 30
$form.Controls.Add($intervalBox)

$lbl4 = New-Object System.Windows.Forms.Label
$lbl4.Text = '分钟执行一次'
$lbl4.Location = New-Object System.Drawing.Point(238, 460)
$lbl4.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($lbl4)

$autostartCheck = New-Object System.Windows.Forms.CheckBox
$autostartCheck.Text = '开机自动启动（后台托盘运行）'
$autostartCheck.Location = New-Object System.Drawing.Point(16, 490)
$autostartCheck.Size = New-Object System.Drawing.Size(260, 22)
$form.Controls.Add($autostartCheck)

$cleanButton = New-Object System.Windows.Forms.Button
$cleanButton.Text = '一键清理'
$cleanButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$cleanButton.Location = New-Object System.Drawing.Point(16, 522)
$cleanButton.Size = New-Object System.Drawing.Size(260, 42)
$form.Controls.Add($cleanButton)

$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Text = '退出程序'
$exitButton.Location = New-Object System.Drawing.Point(292, 522)
$exitButton.Size = New-Object System.Drawing.Size(140, 42)
$form.Controls.Add($exitButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '就绪。点击「一键清理」裁剪当前会话进程的工作集（普通权限即可）。'
$statusLabel.Location = New-Object System.Drawing.Point(16, 576)
$statusLabel.Size = New-Object System.Drawing.Size(548, 24)
$form.Controls.Add($statusLabel)

# ---------- 核心函数 ----------
function Update-MemLabels {
    [NativeMem]::Refresh()
    $totalGB = [Math]::Round([NativeMem]::TotalPhys / 1GB, 2)
    $availGB = [Math]::Round([NativeMem]::AvailPhys / 1GB, 2)
    $usedGB = [Math]::Round($totalGB - $availGB, 2)
    $pct = [NativeMem]::LoadPercent
    $pctLabel.Text = "$pct %"
    $memLabel.Text = "总内存 ${totalGB} GB  |  已用 ${usedGB} GB  |  可用 ${availGB} GB"
    $bar.Value = [int]$pct
    # 与托盘图标一致的冷→暖渐变
    $pctLabel.ForeColor = Get-MemColor $pct
    $bar.ForeColor = Get-MemColor $pct
}

function Update-ProcList {
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 0 } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 15
    $key = ($procs | ForEach-Object { "$($_.Id):$([Math]::Round($_.WorkingSet64 / 1MB))" }) -join ','
    if ($key -eq $script:lastProcKey) { return }
    $script:lastProcKey = $key
    $procList.BeginUpdate()
    $procList.Items.Clear()
    foreach ($p in $procs) {
        $li = New-Object System.Windows.Forms.ListViewItem($p.ProcessName)
        [void]$li.SubItems.Add([string]$p.Id)
        [void]$li.SubItems.Add([string][Math]::Round($p.WorkingSet64 / 1MB))
        [void]$procList.Items.Add($li)
    }
    $procList.EndUpdate()
}

function Invoke-Clean {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        [NativeMem]::Refresh()
        $before = [NativeMem]::AvailPhys
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $n = [NativeMem]::TrimWorkingSets()
        $sw.Stop()
        [NativeMem]::Refresh()
        $after = [NativeMem]::AvailPhys
        $freedMB = [Math]::Max(0, [long](($after - $before) / 1MB))
        $statusLabel.Text = "清理完成：裁剪 $n 个进程，可用内存增加约 ${freedMB} MB（耗时 $($sw.ElapsedMilliseconds) 毫秒）"
    }
    catch {
        $statusLabel.Text = '清理出错：' + $_.Exception.Message
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    Update-MemLabels
}

# ---------- 状态变量 ----------
$script:realExit = $false
$script:trayNotified = $true   # 启动即有托盘图标，避免重复气泡提示
$script:startupBalloonPending = $false
$script:lastProcKey = ''
$script:lastIconBand = -1
$script:lastAutoClean = Get-Date
$script:lastPeriodicClean = Get-Date

# 跨进程"显示主界面"事件：双击快捷方式时由新实例触发，本实例收到后弹出窗口
$script:showEvent = $null
try {
    $script:showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'MemoryCleanerShowEvent')
} catch { }

# ---------- 设置记忆（自动清理/定时清理状态持久化到注册表） ----------
$settingsKey = 'HKCU:\Software\MemoryCleanerTool'
function Save-Settings {
    if (-not (Test-Path $settingsKey)) { New-Item -Path $settingsKey -Force | Out-Null }
    Set-ItemProperty -Path $settingsKey -Name 'AutoClean'         -Value ([int]$autoCleanCheck.Checked) -Force
    Set-ItemProperty -Path $settingsKey -Name 'AutoThreshold'     -Value ([int]$thresholdBox.Value)    -Force
    Set-ItemProperty -Path $settingsKey -Name 'Periodic'          -Value ([int]$periodicCheck.Checked) -Force
    Set-ItemProperty -Path $settingsKey -Name 'PeriodicInterval'  -Value ([int]$intervalBox.Value)     -Force
}
function Load-Settings {
    $p = Get-ItemProperty -Path $settingsKey -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties.Name -contains 'AutoClean') {
        $autoCleanCheck.Checked = ([int]$p.AutoClean -eq 1)
        $thresholdBox.Value = [Math]::Max($thresholdBox.Minimum, [Math]::Min($thresholdBox.Maximum, [int]$p.AutoThreshold))
        $periodicCheck.Checked = ([int]$p.Periodic -eq 1)
        $intervalBox.Value = [Math]::Max($intervalBox.Minimum, [Math]::Min($intervalBox.Maximum, [int]$p.PeriodicInterval))
    }
}
# 控件变化即保存（托盘菜单改的也是这些控件，自动覆盖）
$autoCleanCheck.Add_CheckedChanged({ Save-Settings })
$thresholdBox.Add_ValueChanged({ Save-Settings })
$periodicCheck.Add_CheckedChanged({ Save-Settings })
$intervalBox.Add_ValueChanged({ Save-Settings })
Load-Settings

# ---------- 开机自启（HKCU Run 键） ----------
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($scriptPath)) {
    $autostartCheck.Enabled = $false
    $autostartCheck.Text = '开机自动启动（需保存为 .ps1 文件后使用）'
}
else {
    if ($PSVersionTable.PSEdition -eq 'Core') { $psExe = 'pwsh.exe' } else { $psExe = 'powershell.exe' }
    # 优先使用同目录的 exe 启动器（避免 -ExecutionPolicy Bypass 触发杀软拦截）
    $exePath = Join-Path (Split-Path $scriptPath) 'MemoryCleaner.exe'
    if (Test-Path $exePath) {
        $script:startupCmd = "`"$exePath`" -Minimized"
    }
    else {
        $script:startupCmd = "`"$psExe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$scriptPath`" -Minimized"
    }
    $autostartCheck.Checked = $null -ne (Get-ItemProperty -Path $runKey -Name 'MemoryCleaner' -ErrorAction SilentlyContinue)
}
$autostartCheck.Add_CheckedChanged({
    if ($autostartCheck.Checked) {
        Set-ItemProperty -Path $runKey -Name 'MemoryCleaner' -Value $script:startupCmd -Force
    }
    else {
        Remove-ItemProperty -Path $runKey -Name 'MemoryCleaner' -ErrorAction SilentlyContinue
    }
})

# ---------- 定时器（2 秒刷新 + 自动清理逻辑） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    # 收到其他实例的"显示界面"请求（双击桌面快捷方式）→ 弹出主窗口
    if ($script:showEvent -and $script:showEvent.WaitOne(0)) {
        $form.Show()
        $form.WindowState = 'Normal'
        $form.ShowInTaskbar = $true
        $form.Activate()
    }
    Update-MemLabels
    Update-ProcList
    # 托盘图标按 5% 区间更新（减少闪烁），并更新悬停提示
    $band = [Math]::Floor([NativeMem]::LoadPercent / 5) * 5
    if ($band -ne $script:lastIconBand) {
        $script:lastIconBand = $band
        $oldIcon = $notifyIcon.Icon
        $notifyIcon.Icon = New-MemIcon -Percent $band
        if ($oldIcon) { $oldIcon.Dispose() }
    }
    $availGB = [Math]::Round([NativeMem]::AvailPhys / 1GB, 1)
    $notifyIcon.Text = "内存清理工具 | 使用率 $([NativeMem]::LoadPercent)% | 可用 ${availGB} GB"
    $now = Get-Date
    # 占用超过阈值时自动清理（60 秒冷却，避免频繁触发）
    if ($autoCleanCheck.Checked -and [NativeMem]::LoadPercent -ge [int]$thresholdBox.Value -and ($now - $script:lastAutoClean).TotalSeconds -ge 60) {
        $script:lastAutoClean = $now
        Invoke-Clean
    }
    # 定时清理
    elseif ($periodicCheck.Checked -and ($now - $script:lastPeriodicClean).TotalMinutes -ge [int]$intervalBox.Value) {
        $script:lastPeriodicClean = $now
        Invoke-Clean
    }
    # 开机最小化启动时的托盘提示
    if ($script:startupBalloonPending) {
        $script:startupBalloonPending = $false
        $notifyIcon.ShowBalloonTip(2500, '内存清理工具', '正在后台运行，双击托盘图标可打开主界面', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ---------- 系统托盘 ----------
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = New-MemIcon -Percent 0
$notifyIcon.Text = '内存清理工具 | 正在读取...'
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$mOpen = $trayMenu.Items.Add('打开主界面')
$mClean = $trayMenu.Items.Add('立即清理')
[void]$trayMenu.Items.Add('-')

# 清理时间间隔子菜单（对应主界面"定时清理"的分钟数）
$mInterval = New-Object System.Windows.Forms.ToolStripMenuItem('清理时间间隔')
foreach ($min in 5, 10, 15, 30, 45, 60, 90, 120) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem("$min 分钟")
    $item.Tag = $min
    $item.Add_Click({
        $intervalBox.Value = [int]$this.Tag
        if (-not $periodicCheck.Checked) { $periodicCheck.Checked = $true }
    })
    [void]$mInterval.DropDownItems.Add($item)
}
[void]$trayMenu.Items.Add($mInterval)

# 满XX%清理子菜单（对应主界面"自动清理"的阈值，标题动态显示当前值）
$mThreshold = New-Object System.Windows.Forms.ToolStripMenuItem('满 75% 清理')
foreach ($pct in 50, 60, 70, 75, 80, 85, 90, 95) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem("满 $pct% 清理")
    $item.Tag = $pct
    $item.Add_Click({
        $thresholdBox.Value = [int]$this.Tag
        if (-not $autoCleanCheck.Checked) { $autoCleanCheck.Checked = $true }
    })
    [void]$mThreshold.DropDownItems.Add($item)
}
[void]$trayMenu.Items.Add($mThreshold)

[void]$trayMenu.Items.Add('-')
$mExit = $trayMenu.Items.Add('退出')
$notifyIcon.ContextMenuStrip = $trayMenu

$mOpen.Add_Click({
    $form.Show()
    $form.WindowState = 'Normal'
    $form.ShowInTaskbar = $true
    $form.Activate()
})
$mClean.Add_Click({ Invoke-Clean })
$mExit.Add_Click({ $script:realExit = $true; $form.Close() })

# 打开托盘菜单时：刷新两个子菜单的勾选状态和"满XX%"动态标题
$trayMenu.Add_Opening({
    foreach ($it in $mInterval.DropDownItems) {
        $it.Checked = ([int]$it.Tag -eq [int]$intervalBox.Value)
    }
    foreach ($it in $mThreshold.DropDownItems) {
        $it.Checked = ([int]$it.Tag -eq [int]$thresholdBox.Value)
    }
    $mThreshold.Text = "满 $([int]$thresholdBox.Value)% 清理"
})

$notifyIcon.Add_MouseDoubleClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $form.Show()
        $form.WindowState = 'Normal'
        $form.ShowInTaskbar = $true
        $form.Activate()
    }
})

# ---------- 窗体事件 ----------
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') {
        $form.Hide()
        $form.ShowInTaskbar = $false
        if (-not $script:trayNotified) {
            $script:trayNotified = $true
            $notifyIcon.ShowBalloonTip(2500, '内存清理工具', '已最小化到系统托盘，双击图标可打开主界面', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

# 点关闭按钮 = 最小化到托盘（从托盘菜单「退出」才真正退出）
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:realExit) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:trayNotified) {
            $script:trayNotified = $true
            $notifyIcon.ShowBalloonTip(2500, '内存清理工具', '已最小化到系统托盘，双击图标可打开主界面', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

$form.Add_FormClosed({
    Save-Settings   # 兜底保存设置
    try { if ($script:showEvent) { $script:showEvent.Dispose() } } catch { }
    $notifyIcon.Visible = $false
    try { $notifyIcon.Icon.Dispose() } catch { }
    $notifyIcon.Dispose()
    try { $form.Icon.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
})

$cleanButton.Add_Click({ Invoke-Clean })
$exitButton.Add_Click({ $script:realExit = $true; $form.Close() })

# ---------- 启动 ----------
Update-MemLabels
Update-ProcList
$timer.Start()
$form.Show()
if ($Minimized) {
    $form.Hide()
    $form.ShowInTaskbar = $false
    $script:startupBalloonPending = $true
}
[System.Windows.Forms.Application]::Run($form)
