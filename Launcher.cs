using System;
using System.Diagnostics;
using System.IO;

// MemoryCleaner 启动器：以隐藏窗口方式启动主程序（避免杀毒软件对脚本启动器的误报）
class MemoryCleanerLauncher
{
    [STAThread]
    static void Main(string[] args)
    {
        try
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(dir, "MemoryCleaner.ps1");
            if (!File.Exists(ps1)) return;

            string extra = "";
            if (args != null && args.Length > 0)
            {
                foreach (string a in args) extra += " " + a;
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File \"" + ps1 + "\"" + extra;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
        catch { /* 静默失败，避免弹窗 */ }
    }
}
