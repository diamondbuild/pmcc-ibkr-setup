#!/usr/bin/env bash
# Fix: unzip didn't preserve execute bits on IBC's script files.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/3] Making all IBC shell scripts executable..."
chmod +x /opt/ibc/*.sh
chmod +x /opt/ibc/scripts/*.sh 2>/dev/null || true
chmod +x /opt/ibc/scripts/* 2>/dev/null || true
ls -la /opt/ibc/scripts/ | head -15

echo
echo "[2/3] Restarting gateway service..."
systemctl restart pmcc-gateway.service
sleep 50

echo
echo "Gateway service status:"
systemctl status pmcc-gateway.service --no-pager -l | head -10
echo
echo "Recent logs:"
journalctl -u pmcc-gateway.service -n 40 --no-pager | tail -40

echo
echo "[3/3] Checking proxy..."
systemctl restart pmcc-proxy.service
sleep 5
curl -sS http://localhost:8765/health | python3 -m json.tool || true
