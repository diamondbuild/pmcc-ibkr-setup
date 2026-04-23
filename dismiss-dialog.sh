#!/usr/bin/env bash
# Aggressively dismiss the stuck "Gateway" modal dialog + empty-title window
# that's blocking IBC from enabling the API.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

export DISPLAY=:99

echo "[1/6] Make sure xdotool + wmctrl are present..."
which xdotool >/dev/null || apt-get install -y -qq xdotool
which wmctrl  >/dev/null || apt-get install -y -qq wmctrl

echo
echo "[2/6] Window inventory:"
wmctrl -l 2>/dev/null || echo "  (wmctrl needs wm; using xdotool)"
echo "---"
xdotool search --name "." 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "?")
  geom=$(xdotool getwindowgeometry --shell $wid 2>/dev/null | grep -E '^(WIDTH|HEIGHT|X|Y)=' | tr '\n' ' ')
  echo "  wid=$wid  \"$name\"  $geom"
done | head -30

echo
echo "[3/6] Dump text content (best-effort) of the 'Gateway' dialog..."
GW_WID=$(xdotool search --name "^Gateway$" 2>/dev/null | head -1)
BLANK_WID=$(xdotool search --name "^ $" 2>/dev/null | head -1)
echo "  Gateway dialog wid: $GW_WID"
echo "  Blank-title wid:    $BLANK_WID"

if [[ -n "$GW_WID" ]]; then
  echo "  Geometry of Gateway dialog:"
  xdotool getwindowgeometry $GW_WID 2>/dev/null || true
  # Try xprop for WM state + any text
  xprop -id $GW_WID 2>/dev/null | head -30 || true
fi

echo
echo "[4/6] Install a minimal window manager (openbox) so focus + clicks work..."
# Without a WM, xdotool keystrokes don't always land on the right widget.
if ! which openbox >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openbox >/dev/null
  echo "  openbox installed."
else
  echo "  openbox already installed."
fi
# Start openbox on the display if not already
if ! pgrep -x openbox >/dev/null; then
  openbox --replace --sm-disable &
  sleep 2
  echo "  openbox started."
fi

echo
echo "[5/6] Aggressively dismiss stuck dialogs..."
for wid in $GW_WID $BLANK_WID; do
  [[ -z "$wid" ]] && continue
  echo "  -> Handling wid=$wid ($(xdotool getwindowname $wid 2>/dev/null))"
  xdotool windowactivate --sync $wid 2>/dev/null || true
  xdotool windowfocus --sync $wid 2>/dev/null || true
  xdotool windowraise $wid 2>/dev/null || true
  sleep 0.5

  # Try common accept keys
  for k in Return space Tab+Return "alt+y" "alt+o" Escape; do
    echo "    pressing: $k"
    xdotool key --window $wid $k 2>/dev/null || true
    sleep 0.4
  done

  # Click the center + likely button positions
  eval $(xdotool getwindowgeometry --shell $wid 2>/dev/null)
  if [[ -n "$WIDTH" ]]; then
    CX=$((X + WIDTH / 2))
    BOTTOM_Y=$((Y + HEIGHT - 30))
    echo "    mouse-moving to ($CX, $BOTTOM_Y) and clicking"
    xdotool mousemove $CX $BOTTOM_Y click 1 2>/dev/null || true
    sleep 0.3
  fi
done

echo
echo "[6/6] Result check..."
sleep 3
echo "  Windows now:"
xdotool search --name "." 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "?")
  echo "    wid=$wid  \"$name\""
done | head -20

echo
echo "  IBC log tail:"
tail -12 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt

echo
echo "  Port 4002:"
ss -tlnp | grep 4002 || echo "    (not listening)"

echo
echo "  Health:"
curl -sS http://localhost:8765/health
echo
