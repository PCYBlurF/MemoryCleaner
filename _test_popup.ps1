Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WV {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public static bool HasVisibleWindow(uint pid) {
        bool found = false;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint p; GetWindowThreadProcessId(hWnd, out p);
            if (p == pid && IsWindowVisible(hWnd)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

# 1) 启动实例 A（-Minimized，最小化到托盘）
Start-Process 'G:\Workspace\MemoryCleaner\MemoryCleaner.exe' -ArgumentList '-Minimized'
Start-Sleep -Seconds 8
$procA = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*MemoryCleaner.ps1*' -and $_.CommandLine -notlike '*Get-CimInstance*' } |
    Select-Object -First 1
if (-not $procA) { Write-Output 'FAIL: 实例A未启动'; exit 1 }
$visibleA1 = [WV]::HasVisibleWindow([uint32]$procA.ProcessId)
Write-Output ("实例A运行 PID=" + $procA.ProcessId + " 启动时窗口可见=" + $visibleA1 + " (应为 False=藏在托盘)")

# 2) 模拟双击桌面快捷方式：启动实例 B（无参数）
Start-Process 'G:\Workspace\MemoryCleaner\MemoryCleaner.exe'
Start-Sleep -Seconds 5

# 3) 验证实例 A 是否弹出主窗口
$visibleA2 = [WV]::HasVisibleWindow([uint32]$procA.ProcessId)
Write-Output ("双击后实例A窗口可见=" + $visibleA2 + " (应为 True=已弹出UI)")

# 4) 实例 B 应已自行退出（互斥）
$bAlive = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*MemoryCleaner.ps1*' -and $_.CommandLine -notlike '*Get-CimInstance*' -and $_.ProcessId -ne $procA.ProcessId }
Write-Output ("实例B 残留=" + ($null -ne $bAlive) + " (应为 False=已退出)")

# 清理：结束实例 A
Stop-Process -Id $procA.ProcessId -Force -ErrorAction SilentlyContinue
Write-Output '测试完成，已清理'
