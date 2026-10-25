# Brings the game window to the front and prints the foreground window title.
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class F {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
}
"@
$p = Get-Process | Where-Object { $_.ProcessName -like "DD2*" -or $_.MainWindowTitle -like "*Dragon*" } | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { "no game window"; exit 1 }
[F]::keybd_event(0x12,0,0,[UIntPtr]::Zero); [F]::keybd_event(0x12,0,2,[UIntPtr]::Zero)
[void][F]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 500
$sb = New-Object System.Text.StringBuilder 256; [void][F]::GetWindowText([F]::GetForegroundWindow(), $sb, 256); "fg: " + $sb.ToString()
