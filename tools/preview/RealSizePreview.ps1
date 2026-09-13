<#
.SYNOPSIS
  Mirrors the Connect IQ simulator's watch display at true physical size.

.DESCRIPTION
  The CIQ simulator renders the device at 1:1 logical pixels (then Windows DPI-scales it), which on a
  monitor is 3-6x larger than the watch. This tool captures the simulator window, finds the round
  display, and shows it in a small always-on-top window scaled to the real diameter (33.02 mm for the
  1.3in epix Pro 47mm) using the monitor's true pixel density from its EDID data.

  Design:
    - devices.json      device id -> screen px, physical diameter, canvas color (extend for new devices)
    - region detection  finds the display by the face's canvas color; the last good region is cached in
                        .cache/ so always-on (black) frames keep working
    - monitor PPI       per-monitor, from EDID physical size + physical resolution; -Ppi overrides
    - live or one-shot  live window refreshes every -IntervalMs; -Out writes a single PNG with PPI metadata

  Keys in the live window: Esc closes, + / - zoom, 1 = real size, 2 = double size.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/preview/RealSizePreview.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/preview/RealSizePreview.ps1 -Device epix2pro42mm -Out preview.png
#>
[CmdletBinding()]
param(
    [string]$Device = "epix2pro47mm",
    [double]$DiameterMm = 0,          # override the device table
    [double]$Ppi = 0,                 # override monitor pixel density
    [double]$Zoom = 1.0,              # 1.0 = real size
    [int]$IntervalMs = 1000,
    [string]$Out = "",                # one-shot PNG path instead of a live window
    [string]$Region = "",             # "x,y,w,h" in physical screen px; skips detection
    [string]$ProcessName = "simulator",
    [int]$ColorTolerance = 10,
    [string]$DumpCapture = ""         # debug: also save the raw window capture to this PNG path
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------------------------
# Native helpers. DPI awareness must be set before any window or Screen query, so this runs first.
# ---------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace RealSize {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT pv, int cb);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

        // Full window rectangle as PrintWindow sees it (includes the invisible resize borders).
        public static Rectangle WindowRectRaw(IntPtr hWnd) {
            RECT r; GetWindowRect(hWnd, out r);
            return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
        }

        public static void MakeDpiAware() {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}   // PER_MONITOR_AWARE_V2
            try { SetProcessDpiAwareness(2); } catch {}
        }
        public static Rectangle WindowBounds(IntPtr hWnd) {
            RECT r;
            if (DwmGetWindowAttribute(hWnd, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(hWnd, out r);
            return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
        }
        // Monitor interface id for a screen device name, e.g. \\.\DISPLAY2 -> \\?\DISPLAY#DELA1CE#5&...#{guid}
        public static string MonitorInterfaceId(string screenDeviceName) {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
            if (EnumDisplayDevices(screenDeviceName, 0, ref dd, 1)) return dd.DeviceID;
            return "";
        }
    }

    public static class Pixels {
        // Locates the round display as the largest connected blob of canvas-color pixels. The photo-
        // realistic device bitmap has scattered specks of a similar dark color in the strap/bezel, but
        // only the display forms one large 4-connected region, so labeling it and taking its bounding
        // box isolates the display cleanly regardless of what surrounds it. To bridge the display's
        // own antialiased text and lines (which are not canvas color), matching is tested on a coarse
        // grid cell: a cell counts as "display" if any pixel in it matches, so the blob stays whole.
        // Returns {x, y, side} of the square centered on the blob, in image pixels, or null.
        public static int[] FindDisc(Bitmap bmp, int r, int g, int b, int tol, int minDiameter) {
            const int CELL = 4;
            var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int stride = data.Stride, h = bmp.Height, w = bmp.Width;
            var buf = new byte[stride * h];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(data);

            int gw = (w + CELL - 1) / CELL, gh = (h + CELL - 1) / CELL;
            var cell = new bool[gw * gh];
            for (int y = 0; y < h; y++) {
                int row = y * stride, gy = y / CELL;
                for (int x = 0; x < w; x++) {
                    int i = row + x * 4;
                    if (Math.Abs(buf[i + 2] - r) <= tol && Math.Abs(buf[i + 1] - g) <= tol && Math.Abs(buf[i] - b) <= tol) {
                        cell[gy * gw + x / CELL] = true;
                    }
                }
            }

            var seen = new bool[gw * gh];
            var stack = new int[gw * gh];
            int bestArea = 0; int[] best = null;
            for (int s = 0; s < gw * gh; s++) {
                if (!cell[s] || seen[s]) continue;
                int sp = 0; stack[sp++] = s; seen[s] = true;
                int area = 0, minX = gw, minY = gh, maxX = -1, maxY = -1;
                while (sp > 0) {
                    int c = stack[--sp];
                    int cxg = c % gw, cyg = c / gw;
                    area++;
                    if (cxg < minX) minX = cxg; if (cxg > maxX) maxX = cxg;
                    if (cyg < minY) minY = cyg; if (cyg > maxY) maxY = cyg;
                    if (cxg > 0)      { int n = c - 1;  if (cell[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                    if (cxg < gw - 1) { int n = c + 1;  if (cell[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                    if (cyg > 0)      { int n = c - gw; if (cell[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                    if (cyg < gh - 1) { int n = c + gw; if (cell[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                }
                if (area > bestArea) { bestArea = area; best = new int[] { minX, minY, maxX, maxY }; }
            }
            if (best == null) return null;
            int x0 = best[0] * CELL, y0 = best[1] * CELL;
            int bw = (best[2] - best[0] + 1) * CELL, bh = (best[3] - best[1] + 1) * CELL;
            int d = Math.Max(bw, bh);
            if (d < minDiameter) return null;
            int cx = x0 + bw / 2, cy = y0 + bh / 2;
            return new int[] { cx - d / 2, cy - d / 2, d };
        }
    }
}
"@

[RealSize.Native]::MakeDpiAware()

# ---------------------------------------------------------------------------------------------
# Device geometry
# ---------------------------------------------------------------------------------------------
$devices = Get-Content (Join-Path $here "devices.json") -Raw | ConvertFrom-Json
$dev = $devices.$Device
if (-not $dev) { Write-Warning "Device '$Device' not in devices.json; using default geometry."; $dev = $devices.default }
if ($DiameterMm -le 0) { $DiameterMm = [double]$dev.diameterMm }
$page = [System.Drawing.ColorTranslator]::FromHtml($dev.pageColor)
$deviceLabel = if ($dev.name) { $dev.name } else { $Device }

# ---------------------------------------------------------------------------------------------
# Simulator window
# ---------------------------------------------------------------------------------------------
function Get-SimulatorWindow {
    $p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw "No '$ProcessName' window found. Start the Connect IQ simulator and run the app first." }
    return $p.MainWindowHandle
}

# PrintWindow renders the window's own content even when other windows overlap it (a plain screen copy
# would capture whatever is on top). PW_RENDERFULLCONTENT (2) includes composed/GPU content.
function Get-WindowCapture([IntPtr]$hWnd) {
    $raw = [RealSize.Native]::WindowRectRaw($hWnd)
    $bmp = New-Object System.Drawing.Bitmap $raw.Width, $raw.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [RealSize.Native]::PrintWindow($hWnd, $hdc, 2)
    $g.ReleaseHdc($hdc)
    if (-not $ok) { $g.CopyFromScreen($raw.Left, $raw.Top, 0, 0, $bmp.Size) }
    $g.Dispose()
    return @{ Bitmap = $bmp; Bounds = [RealSize.Native]::WindowBounds($hWnd) }
}

# ---------------------------------------------------------------------------------------------
# Display region: explicit -> detected by canvas color -> cached
# ---------------------------------------------------------------------------------------------
$cacheDir = Join-Path $here ".cache"
$cacheFile = Join-Path $cacheDir "region-$Device.json"
$script:regionOverride = $null
if ($Region) {
    $n = $Region -split "," | ForEach-Object { [int]$_ }
    $script:regionOverride = New-Object System.Drawing.Rectangle $n[0], $n[1], $n[2], $n[3]
}

function Resolve-Region($bmp, $bounds) {
    if ($script:regionOverride) {
        # override is in screen coordinates; translate into the capture
        $r = $script:regionOverride
        return New-Object System.Drawing.Rectangle ($r.X - $bounds.Left), ($r.Y - $bounds.Top), $r.Width, $r.Height
    }
    $disc = [RealSize.Pixels]::FindDisc($bmp, $page.R, $page.G, $page.B, $ColorTolerance, 120)
    if ($disc) {
        $r = New-Object System.Drawing.Rectangle $disc[0], $disc[1], $disc[2], $disc[2]
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
        @{ x = $r.X; y = $r.Y; w = $r.Width; h = $r.Height; captured = (Get-Date).ToString("s") } | ConvertTo-Json | Set-Content $cacheFile -Encoding utf8
        return $r
    }
    if (Test-Path $cacheFile) {
        $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
        return New-Object System.Drawing.Rectangle $c.x, $c.y, $c.w, $c.h
    }
    throw "Could not find the display (looking for canvas color $($dev.pageColor) +/- $ColorTolerance). Make sure the face is awake in the simulator, or pass -Region x,y,w,h."
}

# ---------------------------------------------------------------------------------------------
# Monitor pixel density: EDID physical size / physical resolution, per monitor
# ---------------------------------------------------------------------------------------------
function Get-MonitorPpi([IntPtr]$hWnd) {
    $screen = [System.Windows.Forms.Screen]::FromHandle($hWnd)
    $ifaceId = [RealSize.Native]::MonitorInterfaceId($screen.DeviceName)
    $edid = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue
    $ids = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
    $match = $null
    foreach ($e in $edid) {
        $key = ($e.InstanceName -replace "_0$", "") -replace "\\", "#"
        if ($ifaceId -and $ifaceId.IndexOf($key, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $match = $e; break }
    }
    if (-not $match -and $edid) { $match = $edid | Select-Object -First 1 }
    $name = "monitor"
    if ($match -and $ids) {
        $id = $ids | Where-Object { $_.InstanceName -eq $match.InstanceName } | Select-Object -First 1
        if ($id) { $name = (($id.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join "").Trim() }
    }
    if ($match -and $match.MaxHorizontalImageSize -gt 0) {
        $widthIn = $match.MaxHorizontalImageSize / 2.54
        return @{ Ppi = $screen.Bounds.Width / $widthIn; Source = "EDID $($match.MaxHorizontalImageSize)x$($match.MaxVerticalImageSize) cm, $($screen.Bounds.Width)x$($screen.Bounds.Height) px"; Name = $name }
    }
    $dpi = [RealSize.Native]::GetDpiForWindow($hWnd)
    return @{ Ppi = [double]$dpi; Source = "no EDID size; assuming Windows DPI ($dpi) - pass -Ppi for accuracy"; Name = $name }
}

# ---------------------------------------------------------------------------------------------
# Render: round crop scaled to the physical diameter
# ---------------------------------------------------------------------------------------------
function New-DialImage($src, [System.Drawing.Rectangle]$region, [int]$targetPx) {
    $dial = New-Object System.Drawing.Bitmap $targetPx, $targetPx, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dial)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse(0, 0, $targetPx, $targetPx)
    $g.SetClip($path)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $targetPx, $targetPx), $region, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $dial
}

function Get-Frame([double]$zoom) {
    $hWnd = Get-SimulatorWindow
    $cap = Get-WindowCapture $hWnd
    try {
        if ($DumpCapture) { $cap.Bitmap.Save($DumpCapture, [System.Drawing.Imaging.ImageFormat]::Png) }
        $region = Resolve-Region $cap.Bitmap $cap.Bounds
        $targetPx = [int][math]::Round($DiameterMm / 25.4 * $script:ppiInfo.Ppi * $zoom)
        return @{ Dial = (New-DialImage $cap.Bitmap $region $targetPx); TargetPx = $targetPx; Region = $region; Bounds = $cap.Bounds }
    } finally { $cap.Bitmap.Dispose() }
}

$hWnd0 = Get-SimulatorWindow
$script:ppiInfo = if ($Ppi -gt 0) { @{ Ppi = $Ppi; Source = "-Ppi override"; Name = "monitor" } } else { Get-MonitorPpi $hWnd0 }
$scaleLine = "{0} | {1:N2} mm | {2:N1} ppi ({3}) | zoom {4:N2}" -f $deviceLabel, $DiameterMm, $script:ppiInfo.Ppi, $script:ppiInfo.Name, $Zoom
Write-Host $scaleLine
Write-Host ("ppi source: " + $script:ppiInfo.Source)

# ---------------------------------------------------------------------------------------------
# One-shot
# ---------------------------------------------------------------------------------------------
if ($Out) {
    $f = Get-Frame $Zoom
    $f.Dial.SetResolution([single]$script:ppiInfo.Ppi, [single]$script:ppiInfo.Ppi)
    $f.Dial.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host ("saved {0}: {1}x{1} px = {2:N1} mm at {3:N1} ppi; source region {4}" -f $Out, $f.TargetPx, ($f.TargetPx / $script:ppiInfo.Ppi * 25.4), $script:ppiInfo.Ppi, $f.Region)
    $f.Dial.Dispose()
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Live window
# ---------------------------------------------------------------------------------------------
$script:zoom = $Zoom
$margin = 16
$labelH = 22

$form = New-Object System.Windows.Forms.Form
$form.Text = "Real size"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
$form.TopMost = $true
$form.KeyPreview = $true
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#14181f")
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

$pic = New-Object System.Windows.Forms.PictureBox
$pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::AutoSize
$pic.Location = New-Object System.Drawing.Point $margin, $margin
$form.Controls.Add($pic)

$label = New-Object System.Windows.Forms.Label
$label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#7f92a9")
$label.Font = New-Object System.Drawing.Font "Segoe UI", 8
$label.AutoSize = $true
$form.Controls.Add($label)

function Update-Preview {
    try {
        $f = Get-Frame $script:zoom
        $old = $pic.Image
        $pic.Image = $f.Dial
        if ($old) { $old.Dispose() }
        $label.Text = "{0}  |  {1:N1} mm  |  {2} px  |  {3:N0} ppi  |  x{4:N2}" -f $deviceLabel, ($DiameterMm * $script:zoom), $f.TargetPx, $script:ppiInfo.Ppi, $script:zoom
        $label.Location = New-Object System.Drawing.Point $margin, ($margin + $f.TargetPx + 8)
        $w = [math]::Max($f.TargetPx, $label.PreferredWidth) + 2 * $margin
        $form.ClientSize = New-Object System.Drawing.Size $w, ($margin + $f.TargetPx + 8 + $labelH + $margin / 2)
        if (-not $script:placed) {
            $form.Location = New-Object System.Drawing.Point ($f.Bounds.Right + 12), $f.Bounds.Top
            $script:placed = $true
        }
    } catch {
        $label.Text = $_.Exception.Message
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max(200, $IntervalMs)
$timer.Add_Tick({ Update-Preview })
$form.Add_KeyDown({
    param($s, $e)
    switch ($e.KeyCode) {
        "Escape" { $form.Close() }
        "Add"    { $script:zoom *= 1.25; Update-Preview }
        "Oemplus"{ $script:zoom *= 1.25; Update-Preview }
        "Subtract" { $script:zoom /= 1.25; Update-Preview }
        "OemMinus" { $script:zoom /= 1.25; Update-Preview }
        "D1" { $script:zoom = 1.0; Update-Preview }
        "D2" { $script:zoom = 2.0; Update-Preview }
    }
})
$form.Add_Shown({ Update-Preview; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop() })
[System.Windows.Forms.Application]::Run($form)
