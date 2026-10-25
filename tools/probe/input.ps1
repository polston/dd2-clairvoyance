# Sends input in screen coordinates.
# Usage: input.ps1 click X Y | wheel X Y DELTA | key VK [SCAN] | drag X1 Y1 X2 Y2
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class In {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
}
"@
[void][In]::SetProcessDPIAware()
$a = $args
switch ($a[0]) {
  "click" { [In]::SetCursorPos([int]$a[1],[int]$a[2]); Start-Sleep -Milliseconds 120
            [In]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
            [In]::mouse_event(4,0,0,0,[UIntPtr]::Zero) }
  "wheel" { [In]::SetCursorPos([int]$a[1],[int]$a[2]); Start-Sleep -Milliseconds 120
            [In]::mouse_event(0x800,0,0,[int]$a[3],[UIntPtr]::Zero) }
  "key"   { $vk=[byte][int]$a[1]; $sc=[byte]0; if ($a.Count -gt 2) { $sc=[byte][int]$a[2] }
            [In]::keybd_event($vk,$sc,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
            [In]::keybd_event($vk,$sc,2,[UIntPtr]::Zero) }
}
if ($a[0] -eq "drag") { [In]::SetCursorPos([int]$a[1],[int]$a[2]); Start-Sleep -Milliseconds 150
  [In]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 150
  $n=10; for ($i=1; $i -le $n; $i++) { [In]::SetCursorPos([int]$a[1] + ([int]$a[3]-[int]$a[1])*$i/$n, [int]$a[2] + ([int]$a[4]-[int]$a[2])*$i/$n); Start-Sleep -Milliseconds 40 }
  Start-Sleep -Milliseconds 150; [In]::mouse_event(4,0,0,0,[UIntPtr]::Zero) }
