#!/usr/bin/env bash
# Runs the browser tests. Needs Python 3, Node, and Playwright with Chromium.
# Starts two local servers (one plain, one pointed at a mock Yahoo feed), runs the tests, then stops them.
set -u
cd "$(dirname "$0")/.."
mkdir -p tests/shots
python3 server.py --no-open --stay --port 8787 >/dev/null 2>&1 & A=$!
TICKER_UPSTREAM=http://127.0.0.1:9911/spark python3 server.py --no-open --stay --port 8788 >/dev/null 2>&1 & B=$!
trap 'kill $A $B 2>/dev/null' EXIT
sleep 1
node tests/test_app.js
