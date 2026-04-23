#!/usr/bin/env bash
# Diagnose what IBC is stuck on by listing Xvfb windows, and try to auto-click
# "OK"/"Yes"/"I Agree" on any unknown dialog to unblock the API.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/5] Installing X11 tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq xdotool wmctrl x11-apps x11-utils >/dev/null 2>&1 || true

export DISPLAY=:99

echo
echo "[2/5] All top-level windows on :99 (wmctrl):"
wmctrl -l 2>&1 || echo "  (wmctrl needs a window manager; falling back)"

echo
echo "[3/5] All windows via xdotool:"
xdotool search "" 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "(no name)")
  echo "  wid=$wid name=\"$name\""
done | head -40

echo
echo "[4/5] Window tree (xwininfo):"
xwininfo -root -tree -display :99 2>/dev/null \
  | grep -E '"[^"]+"' | head -25 || true

echo
echo "[5/5] IBC log latest 20 lines:"
tail -20 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt

echo
echo "---"
echo "Port 4002 listening?"
ss -tlnp | grep 4002 || echo "  (no)"

echo
echo "Health:"
curl -sS http://localhost:8765/health
