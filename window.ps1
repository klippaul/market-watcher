# Ticker app: the Windows window (started by server.ps1, nothing to install).
#
# Opens the app in a small frameless window built on Microsoft Edge WebView2, which ships with
# Windows 10 and 11. The page draws its own minimize, close and expand buttons, so there is no
# native title bar. Press and drag the bar to move the window; click the thin bar to throw it to
# the top or bottom edge of the screen. Size and position are remembered between launches.
#
# The first launch downloads Microsoft's WebView2 SDK package (about 9 MB, from nuget.org, checked
# against a pinned SHA-256) and keeps the three files it needs under %LOCALAPPDATA%\Ticker.
# If anything here fails, it falls back to a small Edge or Chrome app window with a normal title bar.
#
#   window.ps1 -Url http://localhost:17872/
#   window.ps1 -Url ... -Browser        skip the frameless window and use the Edge/Chrome app window
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [switch]$Browser
)
$ErrorActionPreference = 'Stop'

$SdkVersion = '1.0.3967.48'
$SdkSha256 = 'C66357AC7F324EC9BCAFE5241706A023B4122D8C22300C31DE4B0EB220DB689E'
$Data = Join-Path $env:LOCALAPPDATA 'Ticker'
$LogFile = Join-Path $Data 'window.log'

function Write-Log([string]$Text) {
  try { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format s) + '  ' + $Text) } catch { }
}

function Open-BrowserWindow {
  # A small chromeless window in Edge (always present on Windows) or Chrome; otherwise the default browser.
  $candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
  )
  foreach ($exe in $candidates) {
    if (Test-Path -LiteralPath $exe) {
      Start-Process -FilePath $exe -ArgumentList "--app=$Url", '--window-size=680,170'
      return
    }
  }
  Start-Process $Url
}

function Get-WebView2Sdk {
  # Returns the folder holding Microsoft.Web.WebView2.Core.dll, WinForms.dll and WebView2Loader.dll.
  $dir = Join-Path $Data "webview2-$SdkVersion"
  $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
  $files = @{
    'lib/net462/Microsoft.Web.WebView2.Core.dll'     = 'Microsoft.Web.WebView2.Core.dll'
    'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = 'Microsoft.Web.WebView2.WinForms.dll'
    "runtimes/win-$arch/native/WebView2Loader.dll"   = 'WebView2Loader.dll'
  }
  $missing = @($files.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir $_)) })
  if ($missing.Count -eq 0) { return $dir }

  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $pkg = Join-Path $Data "webview2-$SdkVersion.nupkg"
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
  Write-Log "Downloading WebView2 SDK $SdkVersion"
  (New-Object Net.WebClient).DownloadFile("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$SdkVersion/microsoft.web.webview2.$SdkVersion.nupkg", $pkg)
  $hash = (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash
  if ($hash -ne $SdkSha256) { Remove-Item -LiteralPath $pkg -Force; throw "WebView2 SDK download did not match its expected checksum ($hash)." }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
  try {
    foreach ($entry in $files.Keys) {
      $e = $zip.GetEntry($entry)
      if (-not $e) { throw "WebView2 SDK package is missing $entry." }
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dir $files[$entry]), $true)
    }
  } finally { $zip.Dispose() }
  Remove-Item -LiteralPath $pkg -Force
  return $dir
}

$Source = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace TickerApp {
  public class TickerWindow : Form {
    // Sizes in CSS pixels (scaled by the monitor's DPI). ThinHeight is the thin bar: the smallest
    // height at which the tape's text still fits. Big is where the page switches to the analysis view.
    const int ThinHeight = 30, MinWidth = 320, DefaultWidth = 960, BigWidth = 760, BigHeight = 440;

    readonly string url, dataDir, stateFile;
    readonly WebView2 web;
    Rectangle compactBounds = Rectangle.Empty;   // last bounds while the window was ticker-sized
    Rectangle beforeFullScreen;
    FormWindowState stateBeforeFullScreen;
    bool fullScreen;
    Timer anim;

    public TickerWindow(string url, string dataDir) {
      this.url = url;
      this.dataDir = dataDir;
      stateFile = Path.Combine(dataDir, "window.txt");
      Text = "Ticker";
      BackColor = Color.FromArgb(26, 26, 25);
      FormBorderStyle = FormBorderStyle.Sizable;
      StartPosition = FormStartPosition.Manual;
      Icon = MakeIcon();
      web = new WebView2();
      web.Dock = DockStyle.Fill;
      web.DefaultBackgroundColor = BackColor;
      Controls.Add(web);
    }

    double DpiScale { get { try { return GetDpiForWindow(Handle) / 96.0; } catch { return DeviceDpi / 96.0; } } }
    int Px(int css) { return (int)Math.Round(css * DpiScale); }

    // frame: keep the resizable border (and Windows snapping), drop the caption
    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      int round = 2; // DWMWCP_ROUND: rounded corners on Windows 11; ignored elsewhere
      try { DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch { }
      int dark = 1;  // dark border colour to match the app
      try { DwmSetWindowAttribute(Handle, 20, ref dark, 4); } catch { }
      SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0027); // SWP_FRAMECHANGED | NOMOVE | NOSIZE | NOZORDER
    }

    protected override void WndProc(ref Message m) {
      const int WM_NCCALCSIZE = 0x83, WM_DPICHANGED = 0x02E0, WM_GETMINMAXINFO = 0x24;
      if (m.Msg == WM_NCCALCSIZE && m.WParam != IntPtr.Zero && !fullScreen) {
        RECT before = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
        base.WndProc(ref m);
        RECT after = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
        // The default sizing gave left, right and bottom borders (invisible on Windows 10 and 11, still
        // grabbable for resizing). Put the top back where it was, so there is no caption.
        after.Top = before.Top + (WindowState == FormWindowState.Maximized ? after.Left - before.Left : 0);
        Marshal.StructureToPtr(after, m.LParam, false);
        m.Result = IntPtr.Zero;
        return;
      }
      if (m.Msg == WM_GETMINMAXINFO) {
        base.WndProc(ref m);
        if (IsHandleCreated && !fullScreen) {
          MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(m.LParam, typeof(MINMAXINFO));
          int ncW = Width - ClientSize.Width, ncH = Height - ClientSize.Height;
          mmi.ptMinTrackSize.X = Px(MinWidth) + ncW;
          mmi.ptMinTrackSize.Y = Px(ThinHeight) + ncH;
          Marshal.StructureToPtr(mmi, m.LParam, false);
        }
        return;
      }
      if (m.Msg == WM_DPICHANGED) {
        RECT r = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
        SetWindowPos(Handle, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, 0x0014); // NOZORDER | NOACTIVATE
        m.Result = IntPtr.Zero;
        return;
      }
      base.WndProc(ref m);
    }

    // The visible window, without the invisible resize borders.
    Rectangle Visible() {
      RECT r;
      if (DwmGetWindowAttribute(Handle, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0) return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
      return Bounds;
    }

    // start-up
    protected override async void OnLoad(EventArgs e) {
      base.OnLoad(e);
      int ncW = Width - ClientSize.Width, ncH = Height - ClientSize.Height;
      Rectangle saved = LoadBounds();
      if (!saved.IsEmpty) Bounds = saved;
      else {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int w = Math.Min(Px(DefaultWidth), wa.Width) + ncW, h = Px(ThinHeight) + ncH;
        Bounds = new Rectangle(wa.Left + (wa.Width - w) / 2, wa.Top, w, h);
      }
      try {
        CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(dataDir, "WebView2"), null);
        await web.EnsureCoreWebView2Async(env);
      } catch (Exception ex) {
        Failed = ex.Message;
        Close();
        return;
      }
      CoreWebView2 core = web.CoreWebView2;
      core.Settings.IsStatusBarEnabled = false;
      core.Settings.IsZoomControlEnabled = false;
      core.Settings.AreDefaultContextMenusEnabled = false;
      core.Settings.IsGeneralAutofillEnabled = false;
      core.Settings.IsPasswordAutosaveEnabled = false;
      core.WebMessageReceived += OnMessage;
      core.ContainsFullScreenElementChanged += delegate { SetFullScreen(web.CoreWebView2.ContainsFullScreenElement); };
      core.DocumentTitleChanged += delegate { Text = web.CoreWebView2.DocumentTitle; };
      core.NewWindowRequested += (s, a) => { a.Handled = true; OpenExternal(a.Uri); };
      core.NavigationStarting += (s, a) => {   // anything that is not the app opens in the normal browser
        if (!a.Uri.StartsWith(Origin(url), StringComparison.OrdinalIgnoreCase)) { a.Cancel = true; OpenExternal(a.Uri); }
      };
      core.Navigate(url);
    }

    public string Failed;
    static string Origin(string u) { Uri x = new Uri(u); return x.GetLeftPart(UriPartial.Authority); }
    static void OpenExternal(string u) {
      if (u.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || u.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) {
        try { Process.Start(u); } catch { }
      }
    }

    // messages from the page
    void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e) {
      string msg;
      try { msg = e.TryGetWebMessageAsString(); } catch { return; }
      switch (msg) {
        case "drag":
          if (fullScreen) return;
          if (WindowState == FormWindowState.Maximized) RestoreUnderCursor();
          ReleaseCapture();
          SendMessage(Handle, 0x00A1, (IntPtr)2, IntPtr.Zero); // WM_NCLBUTTONDOWN on HTCAPTION: Windows moves the window
          break;
        case "throw": Throw(); break;
        case "minimize": WindowState = FormWindowState.Minimized; break;
        case "maximize": if (!fullScreen) WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; break;
        case "quit": Close(); break;
        case "compact":
          if (fullScreen) return;
          WindowState = FormWindowState.Normal;
          if (!compactBounds.IsEmpty && IsBig()) Bounds = compactBounds;
          break;
      }
    }

    bool IsBig() { return ClientSize.Width >= Px(BigWidth) && ClientSize.Height >= Px(BigHeight); }

    void RestoreUnderCursor() {
      Point c = Cursor.Position;
      WindowState = FormWindowState.Normal;
      Rectangle b = !compactBounds.IsEmpty ? compactBounds : Bounds;
      Left = c.X - b.Width / 2;
      Top = c.Y - Px(8);
    }

    // Throw: jump to the top or bottom edge of the screen the window is on. From the top it goes to
    // the bottom and back; from anywhere else it goes to the nearer edge.
    void Throw() {
      if (fullScreen) return;
      if (WindowState != FormWindowState.Normal) WindowState = FormWindowState.Normal;
      Rectangle wa = Screen.FromHandle(Handle).WorkingArea, vis = Visible(), b = Bounds;
      int padTop = vis.Top - b.Top, padLeft = vis.Left - b.Left, padRight = b.Right - vis.Right;
      int topY = wa.Top - padTop, bottomY = wa.Bottom - vis.Height - padTop;
      int target;
      if (Math.Abs(vis.Top - wa.Top) <= 2) target = bottomY;
      else if (Math.Abs(vis.Bottom - wa.Bottom) <= 2) target = topY;
      else target = (vis.Top + vis.Height / 2) < (wa.Top + wa.Height / 2) ? topY : bottomY;
      int x = Math.Max(wa.Left - padLeft, Math.Min(b.Left, wa.Right - vis.Width - padLeft));
      AnimateTo(x, target);
    }

    void AnimateTo(int x, int y) {
      if (anim != null) anim.Stop();
      int x0 = Left, y0 = Top;
      Stopwatch sw = Stopwatch.StartNew();
      anim = new Timer();
      anim.Interval = 10;
      anim.Tick += delegate {
        double t = Math.Min(1.0, sw.ElapsedMilliseconds / 160.0), k = 1 - Math.Pow(1 - t, 3);
        Location = new Point(x0 + (int)Math.Round((x - x0) * k), y0 + (int)Math.Round((y - y0) * k));
        if (t >= 1) { anim.Stop(); SaveBounds(); }
      };
      anim.Start();
    }

    // full screen (the expand button)
    void SetFullScreen(bool on) {
      if (on == fullScreen) return;
      if (on) {
        beforeFullScreen = Bounds;
        stateBeforeFullScreen = WindowState;
        fullScreen = true;
        Screen s = Screen.FromHandle(Handle);
        WindowState = FormWindowState.Normal;
        FormBorderStyle = FormBorderStyle.None;
        Bounds = s.Bounds;
      } else {
        fullScreen = false;
        FormBorderStyle = FormBorderStyle.Sizable;
        SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0027);
        Bounds = beforeFullScreen;
        WindowState = stateBeforeFullScreen == FormWindowState.Maximized ? FormWindowState.Maximized : FormWindowState.Normal;
      }
    }

    protected override void OnResizeEnd(EventArgs e) { base.OnResizeEnd(e); Remember(); SaveBounds(); }
    protected override void OnResize(EventArgs e) { base.OnResize(e); Remember(); }
    protected override void OnMove(EventArgs e) { base.OnMove(e); Remember(); }
    void Remember() {
      if (IsHandleCreated && !fullScreen && WindowState == FormWindowState.Normal && !IsBig()) compactBounds = Bounds;
    }

    protected override void OnFormClosing(FormClosingEventArgs e) { SaveBounds(); base.OnFormClosing(e); }

    // remembered size and position
    void SaveBounds() {
      if (fullScreen || WindowState != FormWindowState.Normal) return;
      Rectangle b = !compactBounds.IsEmpty ? compactBounds : Bounds;
      try { File.WriteAllText(stateFile, b.X + "," + b.Y + "," + b.Width + "," + b.Height); } catch { }
    }
    Rectangle LoadBounds() {
      try {
        string[] p = File.ReadAllText(stateFile).Split(',');
        Rectangle r = new Rectangle(int.Parse(p[0]), int.Parse(p[1]), int.Parse(p[2]), int.Parse(p[3]));
        foreach (Screen s in Screen.AllScreens) {
          Rectangle i = Rectangle.Intersect(s.WorkingArea, r);
          if (i.Width >= 100 && i.Height >= 10) return r;   // still on a connected screen
        }
      } catch { }
      return Rectangle.Empty;
    }

    // Taskbar icon: the same rising line as the app's favicon.
    static Icon MakeIcon() {
      Bitmap bmp = new Bitmap(64, 64);
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath path = new GraphicsPath()) {
          path.AddArc(0, 0, 28, 28, 180, 90); path.AddArc(35, 0, 28, 28, 270, 90);
          path.AddArc(35, 35, 28, 28, 0, 90); path.AddArc(0, 35, 28, 28, 90, 90); path.CloseFigure();
          using (Brush bg = new SolidBrush(Color.FromArgb(26, 26, 25))) g.FillPath(bg, path);
        }
        using (Pen pen = new Pen(Color.FromArgb(12, 163, 12), 6)) {
          pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
          g.DrawLines(pen, new Point[] { new Point(10, 42), new Point(22, 30), new Point(32, 38), new Point(52, 16) });
        }
      }
      return Icon.FromHandle(bmp.GetHicon());
    }

    // Win32
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MINMAXINFO { public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);

    // Returns "" on a normal close, or the reason the window could not be shown.
    public static string Run(string url, string dataDir, string loaderPath) {
      try { SetProcessDpiAwarenessContext((IntPtr)(-4)); } catch { } // per-monitor DPI aware (v2)
      if (LoadLibrary(loaderPath) == IntPtr.Zero) return "could not load " + loaderPath;
      Application.EnableVisualStyles();
      TickerWindow w = new TickerWindow(url, dataDir);
      Application.Run(w);
      return w.Failed ?? "";
    }
  }
}
'@

if ($Browser) { Open-BrowserWindow; exit 0 }
try {
  New-Item -ItemType Directory -Force -Path $Data | Out-Null
  $sdk = Get-WebView2Sdk
  $core = Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll'
  $forms = Join-Path $sdk 'Microsoft.Web.WebView2.WinForms.dll'
  # Compile the window once per version of this file and keep it next to the SDK.
  $sha = [Security.Cryptography.SHA256]::Create()
  $tag = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source + $SdkVersion))) -replace '-', '').Substring(0, 12)
  $dll = Join-Path $sdk "TickerWindow-$tag.dll"
  Add-Type -LiteralPath $core, $forms
  if (-not (Test-Path -LiteralPath $dll)) {
    Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $dll -OutputType Library `
      -ReferencedAssemblies System.Windows.Forms, System.Drawing, $core, $forms
  }
  Add-Type -LiteralPath $dll
  $result = [TickerApp.TickerWindow]::Run($Url, $Data, (Join-Path $sdk 'WebView2Loader.dll'))
  if ($result) { throw $result }
} catch {
  Write-Log ("Frameless window failed, using the browser window instead: " + $_.Exception.Message)
  Open-BrowserWindow
}
