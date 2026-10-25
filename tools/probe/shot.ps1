# Captures the game window to a PNG. Usage: shot.ps1 <out.png>
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref System.Drawing.Point p);
}
"@ -ReferencedAssemblies System.Drawing
[void][W]::SetProcessDPIAware()
$p = Get-Process | Where-Object { $_.ProcessName -like "DD2*" -or $_.MainWindowTitle -like "*Dragon*" } | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { "no game window"; exit 1 }
$r = New-Object W+R
[void][W]::GetClientRect($p.MainWindowHandle, [ref]$r)
$o = New-Object System.Drawing.Point 0, 0
[void][W]::ClientToScreen($p.MainWindowHandle, [ref]$o)
$bmp = New-Object System.Drawing.Bitmap $r.Rt, $r.B
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($o.X, $o.Y, 0, 0, (New-Object System.Drawing.Size $r.Rt, $r.B))
$bmp.Save($args[0])
"saved " + $r.Rt + "x" + $r.B + " at " + $o.X + "," + $o.Y
