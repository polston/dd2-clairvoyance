[CmdletBinding()]
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2",
    [string]$Screenshot,
    [switch]$LocateOnly,
    [int]$TimeoutSeconds = 20
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
public static class QnmlResetNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool PostMessageW(IntPtr h, uint message, UIntPtr wParam, IntPtr lParam);
  public static bool PostWindowKey(IntPtr window, uint key) {
    return PostMessageW(window, 0x0100, new UIntPtr(key), IntPtr.Zero) &&
      PostMessageW(window, 0x0101, new UIntPtr(key), IntPtr.Zero);
  }
  public static bool PostWindowClick(IntPtr window, int x, int y) {
    var packed = new IntPtr(((y & 0xffff) << 16) | (x & 0xffff));
    return PostMessageW(window, 0x0200, UIntPtr.Zero, packed) &&
      PostMessageW(window, 0x0201, new UIntPtr(1), packed) &&
      PostMessageW(window, 0x0202, UIntPtr.Zero, packed);
  }

  private struct Run { public int Start, End, Width; }
  private static bool IsButtonPixel(Color color) {
    return Math.Abs(color.R - 51) <= 3 && Math.Abs(color.G - 52) <= 3 &&
      Math.Abs(color.B - 54) <= 3;
  }
  private static bool HeaderCovers(Bitmap bitmap, Rectangle search, int y,
      int left, int right) {
    var x = search.Left;
    while (x < search.Right) {
      if (!IsButtonPixel(bitmap.GetPixel(x, y))) { ++x; continue; }
      var start = x;
      while (x + 1 < search.Right && IsButtonPixel(bitmap.GetPixel(x + 1, y))) ++x;
      if (start <= left && x >= right) return true;
      ++x;
    }
    return false;
  }
  private static bool HasImmediateHeader(Bitmap bitmap, Rectangle search,
      int left, int right, int buttonTop) {
    var first = Math.Max(search.Top, buttonTop - 40);
    var last = buttonTop - 2;
    var consecutive = 0;
    var lastHeader = -1;
    for (var y = first; y <= last; ++y) {
      if (HeaderCovers(bitmap, search, y, left, right)) {
        ++consecutive;
        lastHeader = y;
      } else {
        if (consecutive >= 3 && buttonTop - lastHeader <= 15) return true;
        consecutive = 0;
        lastHeader = -1;
      }
    }
    return consecutive >= 3 && buttonTop - lastHeader <= 15;
  }
  public static Point[] FindResetTargets(Bitmap bitmap, Rectangle search) {
    if (search.Left < 0 || search.Top < 0 || search.Right > bitmap.Width ||
        search.Bottom > bitmap.Height || search.Width <= 0 || search.Height <= 0) {
      throw new ArgumentOutOfRangeException("search");
    }
    var rows = new Dictionary<string, List<int>>();
    for (var y = search.Top; y < search.Bottom; ++y) {
      var runs = new List<Run>();
      var x = search.Left;
      while (x < search.Right) {
        if (!IsButtonPixel(bitmap.GetPixel(x, y))) { ++x; continue; }
        var start = x;
        while (x + 1 < search.Right && IsButtonPixel(bitmap.GetPixel(x + 1, y))) ++x;
        var width = x - start + 1;
        if (width >= 40 && width <= 180) runs.Add(new Run { Start=start, End=x, Width=width });
        ++x;
      }
      for (var i = 0; i + 2 < runs.Count; ++i) {
        var a = runs[i]; var b = runs[i + 1]; var c = runs[i + 2];
        var gap1 = b.Start - a.End - 1; var gap2 = c.Start - b.End - 1;
        if (a.Width < 40 || a.Width > 90 || b.Width < 50 || b.Width > 110 ||
            c.Width < 80 || c.Width > 180 || gap1 < 2 || gap1 > 15 ||
            gap2 < 2 || gap2 > 15) continue;
        var key = string.Format("{0},{1},{2},{3},{4},{5}",
          a.Start, a.End, b.Start, b.End, c.Start, c.End);
        List<int> ys;
        if (!rows.TryGetValue(key, out ys)) { ys = new List<int>(); rows[key] = ys; }
        ys.Add(y);
      }
    }
    var targets = new List<Point>();
    foreach (var entry in rows) {
      entry.Value.Sort();
      var parts = Array.ConvertAll(entry.Key.Split(','), int.Parse);
      var cluster = new List<int>();
      Action flush = () => {
        if (cluster.Count < 4) { cluster.Clear(); return; }
        if (HasImmediateHeader(bitmap, search, parts[0], parts[5], cluster[0])) {
          var tx = (int)Math.Round((parts[2] + parts[3]) / 2.0,
            MidpointRounding.AwayFromZero);
          var ty = (int)Math.Round((cluster[0] + cluster[cluster.Count - 1]) / 2.0,
            MidpointRounding.AwayFromZero);
          targets.Add(new Point(tx, ty));
        }
        cluster.Clear();
      };
      foreach (var row in entry.Value) {
        if (cluster.Count > 0 && row > cluster[cluster.Count - 1] + 2) flush();
        cluster.Add(row);
      }
      flush();
    }
    return targets.ToArray();
  }
}
"@ -ReferencedAssemblies System.Drawing

[void][QnmlResetNative]::SetProcessDPIAware()

function Find-ResetTarget([System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Rectangle]$Search = [System.Drawing.Rectangle]::Empty) {
    if ($Search.IsEmpty) {
        $Search = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    }
    $targets = @([QnmlResetNative]::FindResetTargets($Bitmap, $Search) |
        Where-Object { Test-ScriptRunnerTarget $Bitmap $Search $_ })
    if ($targets.Count -eq 0) { throw "reset target not found" }
    if ($targets.Count -ne 1) { throw "ambiguous reset target: $($targets.Count) candidates" }
    return $targets[0]
}

function Wait-WinRtOperation($Operation, [Type]$ResultType) {
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq "AsTask" -and $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1 } | Select-Object -First 1
    if (-not $asTask) { throw "Windows OCR task bridge is unavailable" }
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Get-OcrResult([System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Rectangle]$Search, [System.Drawing.Point]$Target) {
    $scale = 4
    $left = $Search.Left
    $top = [Math]::Max($Search.Top, $Target.Y - 45)
    $right = [Math]::Min($Search.Right, $Target.X + 250)
    $bottom = [Math]::Min($Search.Bottom, $Target.Y + 20)
    if ($right -le $left -or $bottom -le $top) { throw "OCR target is empty" }
    $crop = $Bitmap.Clone([System.Drawing.Rectangle]::new(
        $left, $top, $right - $left, $bottom - $top), $Bitmap.PixelFormat)
    try {
        $scaled = [System.Drawing.Bitmap]::new($crop.Width * $scale,
            $crop.Height * $scale)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($scaled)
            try {
                $graphics.InterpolationMode = `
                    [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $graphics.DrawImage($crop, 0, 0, $scaled.Width, $scaled.Height)
            } finally { $graphics.Dispose() }
            $memory = [System.IO.MemoryStream]::new()
            try {
                $scaled.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
                $memory.Position = 0
                $random = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream(
                    $memory)
                try {
                    $decoderType = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
                    $decoder = Wait-WinRtOperation ($decoderType::CreateAsync($random)) `
                        $decoderType
                    $bitmapType = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
                    $software = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) `
                        $bitmapType
                    try {
                        $engineType = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
                        $engine = $engineType::TryCreateFromUserProfileLanguages()
                        if ($null -eq $engine) { throw "Windows OCR engine is unavailable" }
                        $resultType = [Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType = WindowsRuntime]
                        $result = Wait-WinRtOperation ($engine.RecognizeAsync($software)) `
                            $resultType
                    } finally {
                        if ($software -is [System.IDisposable]) { $software.Dispose() }
                    }
                } finally {
                    if ($random -is [System.IDisposable]) { $random.Dispose() }
                }
            } finally { $memory.Dispose() }
        } finally { $scaled.Dispose() }
    } finally { $crop.Dispose() }
    return [pscustomobject]@{
        Result = $result
        Left = $left
        Top = $top
        Scale = $scale
    }
}

function Test-ScriptRunnerTarget([System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Rectangle]$Search, [System.Drawing.Point]$Target) {
    $ocr = Get-OcrResult $Bitmap $Search $Target
    Write-Verbose "reset OCR candidate $($Target.X),$($Target.Y): $($ocr.Result.Text)"
    $targetX = ($Target.X - $ocr.Left) * $ocr.Scale
    $targetY = ($Target.Y - $ocr.Top) * $ocr.Scale
    $headerBound = $false
    $buttonBound = $false
    foreach ($line in $ocr.Result.Lines) {
        $lineWords = @($line.Words)
        foreach ($word in $lineWords) {
            $text = $word.Text.ToLowerInvariant() -replace '[^a-z]', ''
            if ($text -eq "scriptrunner") {
                $rect = $word.BoundingRect
                $gap = $targetY - ($rect.Y + $rect.Height)
                if ($gap -gt 0 -and $gap -le 40 * $ocr.Scale) {
                    $headerBound = $true
                }
            }
        }
        $reset = $lineWords | Where-Object {
            ($_.Text.ToLowerInvariant() -replace '[^a-z]', '') -eq "reset"
        } | Select-Object -First 1
        $scripts = $lineWords | Where-Object {
            ($_.Text.ToLowerInvariant() -replace '[^a-z]', '') -eq "scripts"
        } | Select-Object -First 1
        if ($reset -and $scripts) {
            $leftEdge = [Math]::Min($reset.BoundingRect.X, $scripts.BoundingRect.X)
            $rightEdge = [Math]::Max(
                $reset.BoundingRect.X + $reset.BoundingRect.Width,
                $scripts.BoundingRect.X + $scripts.BoundingRect.Width)
            $topEdge = [Math]::Min($reset.BoundingRect.Y, $scripts.BoundingRect.Y)
            $bottomEdge = [Math]::Max(
                $reset.BoundingRect.Y + $reset.BoundingRect.Height,
                $scripts.BoundingRect.Y + $scripts.BoundingRect.Height)
            $verticalTolerance = 15 * $ocr.Scale
            if ($targetX -ge $leftEdge -and $targetX -le $rightEdge -and
                    $targetY -ge $topEdge - $verticalTolerance -and
                    $targetY -le $bottomEdge + $verticalTolerance) {
                $buttonBound = $true
            }
        }
    }
    Write-Verbose "reset OCR binding header=$headerBound button=$buttonBound"
    return $headerBound -and $buttonBound
}

function Get-ReframeworkBounds([string]$Directory, [int]$ClientWidth,
        [int]$ClientHeight) {
    $uiPath = Join-Path $Directory "ref_ui.ini"
    $logPath = Join-Path $Directory "re2_framework_log.txt"
    if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) {
        throw "REFramework UI state not found: $uiPath"
    }
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "framework log not found: $logPath"
    }
    $hashMatch = Select-String -LiteralPath $logPath `
        -Pattern '\[REFramework\].*Commit hash: ([0-9a-fA-F]+)' | Select-Object -First 1
    if (-not $hashMatch) { throw "current REFramework commit is unreadable" }
    $shortHash = $hashMatch.Matches[0].Groups[1].Value.Substring(0, 8)
    $lines = @(Get-Content -LiteralPath $uiPath)
    $boundsCandidates = [System.Collections.Generic.List[System.Drawing.Rectangle]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].StartsWith("[Window][REFramework [") -or
                -not $lines[$i].Contains($shortHash)) { continue }
        $position = $null
        $size = $null
        for ($j = $i + 1; $j -lt $lines.Count -and
                -not $lines[$j].StartsWith("["); $j++) {
            if ($lines[$j] -match '^Pos=(-?\d+),(-?\d+)$') {
                $position = @([int]$Matches[1], [int]$Matches[2])
            } elseif ($lines[$j] -match '^Size=(\d+),(\d+)$') {
                $size = @([int]$Matches[1], [int]$Matches[2])
            }
        }
        if ($null -ne $position -and $null -ne $size) {
            $windowBounds = [System.Drawing.Rectangle]::new(
                $position[0], $position[1], $size[0], $size[1])
            $boundsCandidates.Add($windowBounds)
        }
    }
    if ($boundsCandidates.Count -ne 1) {
        throw "current REFramework window bounds are ambiguous: $($boundsCandidates.Count) candidates"
    }
    $bounds = $boundsCandidates[0]
    if ($bounds.X -lt 0 -or $bounds.Y -lt 0 -or $bounds.Width -le 0 -or
            $bounds.Height -le 0 -or $bounds.Right -gt $ClientWidth -or
            $bounds.Bottom -gt $ClientHeight) {
        throw "current REFramework window bounds are outside the game client"
    }
    return $bounds
}

function Assert-Foreground([IntPtr]$Window, [string]$Operation) {
    if ([QnmlResetNative]::GetForegroundWindow() -ne $Window) {
        throw "game window lost foreground $Operation"
    }
}

function New-ClientCapture([IntPtr]$Window) {
    Assert-Foreground $Window "before capture"
    $rect = New-Object QnmlResetNative+Rect
    if (-not [QnmlResetNative]::GetClientRect($Window, [ref]$rect)) {
        throw "could not read the game client rectangle"
    }
    $width, $height = $rect.R, $rect.B
    if ($width -le 0 -or $height -le 0) { throw "game client rectangle is empty" }
    $origin = New-Object System.Drawing.Point 0, 0
    if (-not [QnmlResetNative]::ClientToScreen($Window, [ref]$origin)) {
        throw "could not locate the game client rectangle"
    }
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $size = New-Object System.Drawing.Size $width, $height
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $size)
    } finally {
        $graphics.Dispose()
    }
    Assert-Foreground $Window "after capture"
    return $bitmap
}

function Send-WindowKey([IntPtr]$Window, [uint32]$VirtualKey) {
    Assert-Foreground $Window "before overlay key"
    if (-not [QnmlResetNative]::PostWindowKey($Window, $VirtualKey)) {
        throw "could not post the overlay key to the game window"
    }
    Assert-Foreground $Window "after overlay key"
}

function Send-WindowClick([IntPtr]$Window, [int]$X, [int]$Y) {
    Assert-Foreground $Window "before reset click"
    if (-not [QnmlResetNative]::PostWindowClick($Window, $X, $Y)) {
        throw "could not post the reset click to the game window"
    }
    Assert-Foreground $Window "after reset click"
}

function Wait-ForResetLog([string]$Path, [long]$Offset, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $Path
        if ($info.Length -le $Offset) { continue }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader $stream
            try { $added = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally {
            if ($stream) { $stream.Dispose() }
        }
        $reloadIndex = $added.IndexOf("[ScriptRunner] Loading scripts...",
            [System.StringComparison]::Ordinal)
        $readyIndex = if ($reloadIndex -ge 0) {
            $added.IndexOf("CHK ready", $reloadIndex,
                [System.StringComparison]::Ordinal)
        } else { -1 }
        if ($readyIndex -gt $reloadIndex) {
            return $info.Length - $Offset
        }
    }
    throw "Reset Scripts did not produce both ScriptRunner reload and CHK ready evidence"
}

if ($Screenshot) {
    if (-not $LocateOnly) { throw "-Screenshot is available only with -LocateOnly" }
    $bitmap = [System.Drawing.Bitmap]::FromFile(
        [System.IO.Path]::GetFullPath($Screenshot))
    try { $target = Find-ResetTarget $bitmap } finally { $bitmap.Dispose() }
    Write-Output "reset target $($target.X),$($target.Y)"
    exit 0
}
if ($LocateOnly) { throw "-LocateOnly requires -Screenshot" }

$games = @(Get-Process -Name "DD2" -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and
    [QnmlResetNative]::IsWindowVisible($_.MainWindowHandle)
})
if ($games.Count -ne 1) {
    throw "expected exactly one visible DD2 game window; found $($games.Count)"
}
$game = $games[0]
$window = $game.MainWindowHandle
[void][QnmlResetNative]::ShowWindow($window, 9)
if (-not [QnmlResetNative]::IsWindowVisible($window)) {
    throw "could not show the DD2 game window"
}
if (-not [QnmlResetNative]::SetForegroundWindow($window)) {
    throw "could not foreground the DD2 game window"
}
Start-Sleep -Milliseconds 350
Assert-Foreground $window "before reset discovery"

$openedOverlay = $false
try {
    $bitmap = New-ClientCapture $window
    try {
        $bounds = Get-ReframeworkBounds $GameDir $bitmap.Width $bitmap.Height
        try { $target = Find-ResetTarget $bitmap $bounds } catch {
            if ($_.Exception.Message -ne "reset target not found") { throw }
            $target = $null
        }
    } finally { $bitmap.Dispose() }
    if (-not $target) {
        Send-WindowKey $window 0x2D
        $openedOverlay = $true
        Start-Sleep -Milliseconds 500
        $bitmap = New-ClientCapture $window
        try {
            $bounds = Get-ReframeworkBounds $GameDir $bitmap.Width $bitmap.Height
            $target = Find-ResetTarget $bitmap $bounds
        } finally { $bitmap.Dispose() }
    }

    $logPath = Join-Path $GameDir "re2_framework_log.txt"
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "framework log not found: $logPath"
    }
    $before = (Get-Item -LiteralPath $logPath).Length
    Send-WindowClick $window $target.X $target.Y
    $growth = Wait-ForResetLog $logPath $before $TimeoutSeconds
} finally {
    if ($openedOverlay) {
        Start-Sleep -Milliseconds 200
        Send-WindowKey $window 0x2D
    }
}
Write-Output "reset-scripts: reset confirmed (framework log +$growth bytes)"
