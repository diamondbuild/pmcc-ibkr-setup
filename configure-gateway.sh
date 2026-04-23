#!/usr/bin/env bash
# Writes IBC config, sets up gateway launcher + systemd service, starts it.
# Usage: IBKR_USER=... IBKR_PASS=... bash configure-gateway.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"; exit 1
fi

: "${IBKR_USER:?IBKR_USER env var required}"
: "${IBKR_PASS:?IBKR_PASS env var required}"
TRADING_MODE="${TRADING_MODE:-paper}"

echo "[1/5] Writing IBC config..."
mkdir -p /opt/ibc

# Find the installed Gateway directory
GW_DIR=$(ls -d /root/Jts/ibgateway/* 2>/dev/null | head -1 || true)
if [[ -z "$GW_DIR" ]]; then
  GW_DIR=$(ls -d /opt/ibgateway/* 2>/dev/null | head -1 || true)
fi
if [[ -z "$GW_DIR" ]]; then
  echo "ERROR: Cannot find installed IB Gateway directory"
  exit 1
fi
echo "  Found Gateway at: $GW_DIR"

# IBC's config.ini — minimal working config for paper trading read-only
cat > /opt/ibc/config.ini <<EOF
IbLoginId=${IBKR_USER}
IbPassword=${IBKR_PASS}
TradingMode=${TRADING_MODE}
IbDir=/root/Jts
FIX=no
StoreSettingsOnServer=no
AcceptIncomingConnectionAction=accept
ReadOnlyApi=yes
IbAutoClosedown=no
ClosedownAt=
AllowBlindTrading=no
MinimizeMainWindow=yes
OverrideTwsApiPort=4002
SendMarketDataInLotsForUSstocks=no
AcceptNonBrokerageAccountWarning=yes
AutoLogoffDisabled=yes
ReloginAfterSecondFactorAuthenticationTimeout=yes
ExitAfterSecondFactorAuthenticationTimeout=no
LogToConsole=no
EOF
chmod 600 /opt/ibc/config.ini
echo "  Config written (password redacted from logs)"

echo "[2/5] Creating Gateway launcher script..."
# Small wrapper that runs IBC under Xvfb so Gateway's Java UI can initialize headlessly
cat > /opt/ibc/run-gateway.sh <<EOF
#!/usr/bin/env bash
set -e
export DISPLAY=:99
# Start virtual X display if not running
if ! pgrep -x Xvfb >/dev/null; then
  Xvfb :99 -screen 0 1024x768x16 &
  sleep 2
fi
cd /opt/ibc
exec ./gatewaystart.sh
EOF
chmod +x /opt/ibc/run-gateway.sh

# Ensure IBC points to the right Gateway path — detect installed version
sed -i "s|^IBC_PATH=.*|IBC_PATH=/opt/ibc|" /opt/ibc/gatewaystart.sh 2>/dev/null || true
sed -i "s|^TWS_PATH=.*|TWS_PATH=/root/Jts|" /opt/ibc/gatewaystart.sh 2>/dev/null || true
# Also set config path so IBC finds our config.ini
sed -i "s|^IBC_INI=.*|IBC_INI=/opt/ibc/config.ini|" /opt/ibc/gatewaystart.sh 2>/dev/null || true

echo "[3/5] Creating systemd service for Gateway..."
cat > /etc/systemd/system/pmcc-gateway.service <<'UNIT'
[Unit]
Description=IB Gateway (managed by IBC) for PMCC Radar
After=network-online.target
Wants=network-online.target
Before=pmcc-proxy.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:99
ExecStartPre=/bin/bash -c '/usr/bin/Xvfb :99 -screen 0 1024x768x16 &'
ExecStart=/opt/ibc/gatewaystart.sh
Restart=always
RestartSec=30
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pmcc-gateway.service >/dev/null

echo "[4/5] Starting Gateway (this can take 60-90 seconds)..."
systemctl restart pmcc-gateway.service
sleep 45

# Check if Gateway process is alive
if pgrep -f "ibgateway" >/dev/null || pgrep -f "jts4launch" >/dev/null; then
  echo "  Gateway process running"
else
  echo "  Gateway process not yet visible — checking status..."
  systemctl status pmcc-gateway.service --no-pager -l | tail -15
fi

echo "[5/5] Restarting proxy so it reconnects to freshly-started Gateway..."
systemctl restart pmcc-proxy.service
sleep 5

echo
echo "=================================================="
echo "  Done. Status check:"
echo "=================================================="
echo
echo "--- Gateway logs (last 20 lines) ---"
journalctl -u pmcc-gateway.service -n 20 --no-pager || true
echo
echo "--- Proxy logs (last 10 lines) ---"
journalctl -u pmcc-proxy.service -n 10 --no-pager || true
echo
echo "--- Proxy health check ---"
sleep 3
curl -sS http://localhost:8765/health | python3 -m json.tool || echo "(proxy not responding yet)"
echo
echo "If gateway_connected is still false, wait 30 seconds and run:"
echo "  curl -sS http://localhost:8765/health"
echo
