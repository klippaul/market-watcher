# Ticker app: tiny local server for Windows (built-in PowerShell, nothing to install).
#
# Serves index.html and relays price requests to Yahoo Finance, because a browser
# page is not allowed to call Yahoo directly. It listens on localhost only and
# stops by itself a few minutes after the Ticker window is closed.
#
#   Start Ticker.cmd                 double-click to launch (runs this file)
#   server.ps1 -Port 9000            use another port (default 17872)
#   server.ps1 -NoOpen               start without opening a window
#   server.ps1 -Stay                 keep running after the window closes
#   server.ps1 -Browser              open an Edge/Chrome app window instead of the frameless one
param(
  [int]$Port = 17872,
  [switch]$NoOpen,
  [switch]$Stay,
  [switch]$Browser
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Upstream = 'https://query1.finance.yahoo.com/v7/finance/spark'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$IdleSeconds = 180
$Ranges = @('1d', '5d', '1mo', '3mo', '6mo', '1y', '2y')
$Intervals = @('1m', '2m', '5m', '15m', '30m', '60m', '1d', '1wk')

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Open-TickerWindow([string]$Url) {
  # window.ps1 opens the frameless Ticker window (or falls back to an Edge/Chrome app window).
  # (one string with quoted paths, because Start-Process does not quote array items containing spaces)
  $psArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Root 'window.ps1') + '" -Url "' + $Url + '"'
  if ($Browser) { $psArgs += ' -Browser' }
  Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden
}

function Test-PortBusy([int]$P) {
  # True when any program is already listening on this port (IPv4 or IPv6 loopback).
  foreach ($addr in @('127.0.0.1', '::1')) {
    $client = $null
    try {
      $ip = [Net.IPAddress]::Parse($addr)
      $client = New-Object Net.Sockets.TcpClient($ip.AddressFamily)
      if ($client.ConnectAsync($ip, $P).Wait(300) -and $client.Connected) { return $true }
    } catch { } finally { if ($client) { $client.Close() } }
  }
  return $false
}

function Test-TickerRunning([int]$P) {
  try {
    $req = [Net.HttpWebRequest]::Create("http://localhost:$P/api/ping")
    $req.Timeout = 1500
    $resp = $req.GetResponse()
    $reader = New-Object IO.StreamReader($resp.GetResponseStream())
    $text = $reader.ReadToEnd()
    $resp.Close()
    return ($text -like '*ticker-app*')
  } catch { return $false }
}

function Send-Bytes($Context, [int]$Code, [string]$Type, [byte[]]$Bytes) {
  $r = $Context.Response
  $r.StatusCode = $Code
  $r.ContentType = $Type
  $r.Headers['Cache-Control'] = 'no-store'
  $r.ContentLength64 = $Bytes.Length
  $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $r.OutputStream.Close()
}

function Send-Text($Context, [int]$Code, [string]$Type, [string]$Text) {
  Send-Bytes $Context $Code $Type ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Send-Spark($Context) {
  $q = $Context.Request.QueryString
  $symbols = [string]$q['symbols']
  $range = [string]$q['range']
  $interval = [string]$q['interval']
  if ($symbols -notmatch '^[A-Za-z0-9.,^=\-]{1,300}$' -or $Ranges -notcontains $range -or $Intervals -notcontains $interval) {
    Send-Text $Context 400 'application/json' '{"error":"bad request"}'
    return
  }
  $target = $Upstream + '?symbols=' + [Uri]::EscapeDataString($symbols).Replace('%2C', ',') + "&range=$range&interval=$interval"
  $resp = $null
  try {
    $req = [Net.HttpWebRequest]::Create($target)
    $req.UserAgent = $UserAgent
    $req.Accept = 'application/json'
    $req.Timeout = 15000
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $resp = $req.GetResponse()
  } catch {
    $base = $_.Exception.GetBaseException()
    if ($base -is [Net.WebException] -and $base.Response) {
      $resp = $base.Response          # Yahoo answered with an error status; pass it through
    } else {
      $msg = ($base.Message -replace '["\\\r\n]', ' ')
      Send-Text $Context 502 'application/json' ('{"error":"' + $msg + '"}')
      return
    }
  }
  try {
    $ms = New-Object IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $code = [int]$resp.StatusCode
  } finally { $resp.Close() }
  Send-Bytes $Context $code 'application/json' $ms.ToArray()
}

function Invoke-Request($Context) {
  $path = $Context.Request.Url.AbsolutePath
  if ($Context.Request.HttpMethod -ne 'GET') { Send-Text $Context 405 'text/plain' 'Method not allowed'; return }
  if ($path -eq '/' -or $path -eq '/index.html') {
    Send-Bytes $Context 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $Root 'index.html')))
  } elseif ($path -eq '/api/ping') {
    Send-Text $Context 200 'application/json' '{"app":"ticker-app"}'
  } elseif ($path -eq '/api/spark') {
    Send-Spark $Context
  } else {
    Send-Text $Context 404 'text/plain' 'Not found'
  }
}

# Find a port. A port that something else already answers on is skipped, unless that
# something is Ticker itself, in which case its window is simply opened again.
$listener = $null
for ($p = $Port; $p -lt $Port + 10; $p++) {
  if (Test-PortBusy $p) {
    if (Test-TickerRunning $p) {
      if (-not $NoOpen) { Open-TickerWindow "http://localhost:$p/" }
      exit 0
    }
    continue
  }
  try {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    $l.Start()
    $listener = $l
    $Port = $p
    break
  } catch { }
}
if (-not $listener) { Write-Error "Could not find a free port near $Port."; exit 1 }

$url = "http://localhost:$Port/"
Write-Host "Ticker is running at $url"
if (-not $NoOpen) { Open-TickerWindow $url }

$lastHit = [DateTime]::UtcNow
$pending = $listener.GetContextAsync()
try {
  while ($true) {
    $ready = $false
    try { $ready = $pending.Wait(1000) } catch { Start-Sleep -Milliseconds 200; $pending = $listener.GetContextAsync(); continue }
    if (-not $ready) {
      if (-not $Stay -and ([DateTime]::UtcNow - $lastHit).TotalSeconds -gt $IdleSeconds) { break }
      continue
    }
    $context = $pending.Result
    $pending = $listener.GetContextAsync()
    $lastHit = [DateTime]::UtcNow
    try { Invoke-Request $context } catch {
      try { $context.Response.StatusCode = 500; $context.Response.Close() } catch { }
    }
  }
} finally {
  $listener.Stop()
}
