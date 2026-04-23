#!/usr/bin/env bash
# Disable automated IBC login so the user can log in manually via VNC once.
# Launch Gateway directly (without IBC) for the one-time config.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/6] Stopping all Gateway/IBC/VNC processes..."
systemctl stop pmcc-gateway.service pmcc-vnc.service 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f ibgateway 2>/dev/null || true
pkill -9 -f 'java.*IBC' 2>/dev/null || true
pkill -9 -f 'java.*ibc' 2>/dev/null || true
pkill -9 -f openbox 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
sleep 3
echo "  Clean."

echo
echo "[2/6] Updating IBC config.ini with correct username..."
sed -i 's/^IbLoginId=.*/IbLoginId=joeyangelo818/' /opt/ibc/config.ini
grep -E '^(IbLoginId|IbPassword|TradingMode)' /opt/ibc/config.ini

echo
echo "[3/6] Writing a manual-mode wrapper (Xvfb + openbox + Gateway directly, NO IBC)..."
cat > /opt/ibc/run-gateway-manual.sh <<'WRAPPER'
#!/usr/bin/env bash
# Run Gateway with manual login (no IBC), so user can log in via VNC once
# and let Gateway save its settings.
set -e
rm -f /tmp/.X99-lock 2>/dev/null || true
Xvfb :99 -screen 0 1280x800x16 >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=:99
sleep 3

openbox --sm-disable >/tmp/openbox.log 2>&1 &
OB_PID=$!
sleep 2

trap "kill -TERM $XVFB_PID $OB_PID 2>/dev/null; pkill -f ibgateway 2>/dev/null; exit 0" TERM INT

# Launch Gateway directly using its bundled java + install4j jar
cd /root/Jts/ibgateway/1037 || cd /opt/ibgateway
exec ./ibgateway
WRAPPER
chmod +x /opt/ibc/run-gateway-manual.sh

# Check that Gateway has a launchable binary
if [[ -x /opt/ibgateway/ibgateway ]]; then
  echo "  Gateway binary: /opt/ibgateway/ibgateway ✓"
elif [[ -x /root/Jts/ibgateway/1037/ibgateway ]]; then
  echo "  Gateway binary: /root/Jts/ibgateway/1037/ibgateway ✓"
else
  echo "  WARN: no ibgateway binary found directly; listing..."
  ls -la /opt/ibgateway/ 2>/dev/null | head -15
  ls -la /root/Jts/ibgateway/1037/ 2>/dev/null | head -15
fi

echo
echo "[4/6] Starting Xvfb + openbox + x11vnc (NO auto-login)..."
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1280x800x16 >/dev/null 2>&1 &
export DISPLAY=:99
sleep 3
openbox --sm-disable >/tmp/openbox.log 2>&1 &
sleep 2

# Start VNC
x11vnc -display :99 -rfbauth /root/.vncpasswd -rfbport 5900 -forever -shared -noxdamage -bg >/tmp/x11vnc.log 2>&1
sleep 2
echo "  Xvfb: $(pgrep -f 'Xvfb :99' || echo 'not running')"
echo "  openbox: $(pgrep -x openbox || echo 'not running')"
echo "  x11vnc: $(pgrep -x x11vnc || echo 'not running')"
echo "  Port 5900: $(ss -tln | grep -c ':5900 ') listener(s)"

echo
echo "[5/6] Launching Gateway UI (no auto-login, you log in via VNC)..."
if [[ -x /opt/ibgateway/ibgateway ]]; then
  cd /opt/ibgateway
  nohup ./ibgateway >/tmp/gateway-manual.log 2>&1 &
  GW_PID=$!
elif [[ -x /root/Jts/ibgateway/1037/ibgateway ]]; then
  cd /root/Jts/ibgateway/1037
  nohup ./ibgateway >/tmp/gateway-manual.log 2>&1 &
  GW_PID=$!
else
  echo "  ERROR: can't find ibgateway binary. Falling back to java -jar..."
  cd /opt/ibgateway
  JAR=$(ls /opt/ibgateway/jars/twslaunch-*.jar 2>/dev/null | head -1)
  [[ -z "$JAR" ]] && JAR=$(ls /root/Jts/ibgateway/1037/jars/twslaunch-*.jar | head -1)
  JRE=$(ls -d /opt/i4j_jres/*/bin/java 2>/dev/null | head -1)
  [[ -z "$JRE" ]] && JRE=/usr/bin/java
  echo "  Using JRE: $JRE"
  echo "  Using JAR: $JAR"
  cd /root/Jts
  nohup "$JRE" -jar "$JAR" >/tmp/gateway-manual.log 2>&1 &
  GW_PID=$!
fi

sleep 8
echo "  Gateway PID: $GW_PID"
echo "  Process alive? $(kill -0 $GW_PID 2>/dev/null && echo 'YES' || echo 'NO - check /tmp/gateway-manual.log')"

if ! kill -0 $GW_PID 2>/dev/null; then
  echo
  echo "  Gateway exited immediately. Log tail:"
  tail -20 /tmp/gateway-manual.log
fi

echo
echo "[6/6] Window check (should see IBKR Gateway login window)..."
sleep 3
xdotool search --name "." 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null)
  echo "  wid=$wid \"$name\""
done | head -15

echo
echo "============================================"
echo "  VNC into 198.199.86.74:5900 now."
echo "  Password: pmccvnc2026"
echo "  Log in with:"
echo "    Username: joeyangelo818"
echo "    Password: Tr@in8181295"
echo "    (Paper Trading already selected)"
echo
echo "  After login + API config, run:"
echo "    ss -tln | grep 4002"
echo "  to confirm API port is open."
echo "============================================"
