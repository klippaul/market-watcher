#!/usr/bin/env python3
"""Ticker app: tiny local server (Mac, Linux, or Windows with Python 3.8+).

Serves index.html and relays price requests to Yahoo Finance, because a
browser page is not allowed to call Yahoo directly. Standard library only.

    python3 server.py              start and open the app window
    python3 server.py --no-open    start without opening a window
    python3 server.py --port 9000  use another port
    python3 server.py --stay       keep running after the window closes
"""
import argparse
import gzip
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
UPSTREAM = os.environ.get("TICKER_UPSTREAM", "https://query1.finance.yahoo.com/v7/finance/spark")
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
SYMBOLS_RE = re.compile(r"^[A-Za-z0-9.,^=\-]{1,300}$")
RANGES = {"1d", "5d", "1mo", "3mo", "6mo", "1y", "2y"}
INTERVALS = {"1m", "2m", "5m", "15m", "30m", "60m", "1d", "1wk"}
IDLE_SECONDS = 180
last_hit = time.time()


class Handler(BaseHTTPRequestHandler):
    server_version = "TickerApp/1.0"

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global last_hit
        last_hit = time.time()
        url = urllib.parse.urlsplit(self.path)
        if url.path in ("/", "/index.html"):
            with open(os.path.join(ROOT, "index.html"), "rb") as f:
                return self.send(200, "text/html; charset=utf-8", f.read())
        if url.path == "/api/ping":
            return self.send(200, "application/json", b'{"app":"ticker-app"}')
        if url.path == "/api/spark":
            return self.spark(urllib.parse.parse_qs(url.query))
        self.send(404, "text/plain; charset=utf-8", b"Not found")

    def spark(self, q):
        symbols = (q.get("symbols") or [""])[0]
        rng = (q.get("range") or ["1d"])[0]
        interval = (q.get("interval") or ["5m"])[0]
        if not SYMBOLS_RE.match(symbols) or rng not in RANGES or interval not in INTERVALS:
            return self.send(400, "application/json", b'{"error":"bad request"}')
        target = "%s?symbols=%s&range=%s&interval=%s" % (
            UPSTREAM, urllib.parse.quote(symbols, safe=","), rng, interval)
        req = urllib.request.Request(target, headers={
            "User-Agent": UA, "Accept": "application/json", "Accept-Encoding": "gzip"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                body, code = r.read(), r.status
                if r.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
        except urllib.error.HTTPError as e:
            body, code = e.read(), e.code
            if e.headers.get("Content-Encoding") == "gzip":
                try:
                    body = gzip.decompress(body)
                except OSError:
                    pass
        except Exception as e:  # network down, DNS failure, timeout
            return self.send(502, "application/json", json.dumps({"error": str(e)}).encode())
        self.send(code, "application/json", body)


def already_running(port):
    try:
        with urllib.request.urlopen("http://localhost:%d/api/ping" % port, timeout=2) as r:
            return b"ticker-app" in r.read()
    except Exception:
        return False


def port_busy(port):
    """True when any program is already listening on this port."""
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:
                s.settimeout(0.3)
                if s.connect_ex((addr, port)) == 0:
                    return True
        except OSError:
            pass
    return False


def open_window(url):
    """Open a small chromeless window when Chrome or Edge is available, else the default browser."""
    flags = ["--app=" + url, "--window-size=680,170"]
    if sys.platform == "darwin":
        for app in ("Google Chrome", "Microsoft Edge", "Brave Browser"):
            if os.path.exists("/Applications/%s.app" % app):
                subprocess.Popen(["open", "-na", app, "--args"] + flags)
                return
    elif os.name == "nt":
        roots = [os.environ.get(k, "") for k in ("ProgramFiles(x86)", "ProgramFiles", "LocalAppData")]
        for sub in (r"Microsoft\Edge\Application\msedge.exe", r"Google\Chrome\Application\chrome.exe"):
            for root in roots:
                exe = os.path.join(root, sub)
                if root and os.path.exists(exe):
                    subprocess.Popen([exe] + flags)
                    return
    else:
        for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge"):
            exe = shutil.which(name)
            if exe:
                subprocess.Popen([exe] + flags, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
    webbrowser.open(url)


def main():
    ap = argparse.ArgumentParser(description="Ticker app local server")
    ap.add_argument("--port", type=int, default=17872)
    ap.add_argument("--no-open", action="store_true", help="do not open a window")
    ap.add_argument("--stay", action="store_true", help="keep running after the window closes")
    args = ap.parse_args()

    port, server = args.port, None
    for candidate in range(args.port, args.port + 10):
        if already_running(candidate):
            print("Ticker is already running on port %d." % candidate)
            if not args.no_open:
                open_window("http://localhost:%d/" % candidate)
            return
        if port_busy(candidate):  # some other program owns this port
            continue
        try:
            server = ThreadingHTTPServer(("127.0.0.1", candidate), Handler)
            port = candidate
            break
        except OSError:
            continue
    if server is None:
        sys.exit("Could not find a free port near %d." % args.port)

    url = "http://localhost:%d/" % port
    print("Ticker is running at %s  (Ctrl+C to stop)" % url)
    if not args.no_open:
        open_window(url)

    if not args.stay:
        def watchdog():  # stop once the window has been closed for a few minutes
            while time.time() - last_hit < IDLE_SECONDS:
                time.sleep(5)
            server.shutdown()
        threading.Thread(target=watchdog, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
