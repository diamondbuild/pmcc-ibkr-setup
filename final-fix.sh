#!/usr/bin/env bash
# Final fix: rewrite systemd unit to handle Xvfb + gateway in a proper wrapper,
# kill all zombie processes, restart clean.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/5] Stopping gateway service and killing leftover processes..."
systemctl stop pmcc-gateway.service 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f ibgateway 2>/dev/null || true
pkill -9 -f IBController 2>/dev/null || true
pkill -9 -f 'java.*IBC' 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
sleep 2
echo "  Done."

echo
echo "[2/5] Writing wrapper script for gateway + Xvfb..."
cat > /opt/ibc/run-gateway-wrapped.sh <<'WRAPPER'
#!/usr/bin/env bash
# Start Xvfb (if not running), then launch IBC's gatewaystart.sh in foreground.
set -e

# Clean up stale X locks from previous unclean exits
rm -f /tmp/.X99-lock 2>/dev/null || true

# Start Xvfb in background; systemd will kill everything when we exit
Xvfb :99 -screen 0 1024x768x16 >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=:99

# Ensure Xvfb started
sleep 3
if ! kill -0 $XVFB_PID 2>/dev/null; then
  echo "Xvfb failed to start"
  exit 1
fi

# Make sure child processes die with us
trap "kill -TERM $XVFB_PID 2>/dev/null; pkill -f ibgateway 2>/dev/null; exit 0" TERM INT

# Launch gateway in foreground (-inline flag makes it not fork)
exec /opt/ibc/gatewaystart.sh -inline
WRAPPER
chmod +x /opt/ibc/run-gateway-wrapped.sh
echo "  Wrapper written."

echo
echo "[3/5] Rewriting systemd unit (no more broken ExecStartPre)..."
cat > /etc/systemd/system/pmcc-gateway.service <<'UNIT'
[Unit]
Description=IB Gateway (managed by IBC) for PMCC Radar
After=network-online.target
Wants=network-online.target
Before=pmcc-proxy.service

[Service]
Type=simple
User=root
ExecStart=/opt/ibc/run-gateway-wrapped.sh
ExecStopPost=/usr/bin/pkill -f Xvfb
Restart=always
RestartSec=30
TimeoutStartSec=180
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
echo "  Unit rewritten."

echo
echo "[4/5] Starting gateway service..."
systemctl start pmcc-gateway.service
echo "  Waiting 70 seconds for IBKR login..."
for i in $(seq 1 14); do
  sleep 5
  status=$(systemctl is-active pmcc-gateway.service)
  if [[ "$status" != "active" ]] && [[ "$status" != "activating" ]]; then
    echo "  Service died (status: $status). Showing logs..."
    break
  fi
  printf "  [%02d/14] service: %s\n" $i "$status"
done

echo
echo "Gateway service status:"
systemctl status pmcc-gateway.service --no-pager -l | head -12

echo
echo "Latest 25 log lines:"
journalctl -u pmcc-gateway.service -n 25 --no-pager | tail -25

echo
echo "[5/5] Restarting proxy + health check..."
systemctl restart pmcc-proxy.service
sleep 5
curl -sS http://localhost:8765/health | python3 -m json.tool || echo "(proxy not responding)"
echo
echo "If gateway_connected is still false, wait 30s more and run:"
echo "  curl -sS http://localhost:8765/health"
