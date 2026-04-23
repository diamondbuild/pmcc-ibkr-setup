#!/usr/bin/env bash
# Pull latest proxy.py from repo and restart the service.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/3] Fetching latest proxy.py..."
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/diamondbuild/pmcc-ibkr-setup/contents/proxy.py \
  -o /opt/pmcc-proxy/proxy.py
echo "  Downloaded $(wc -l < /opt/pmcc-proxy/proxy.py) lines."

echo
echo "[2/3] Restarting proxy..."
systemctl restart pmcc-proxy.service
sleep 6

echo
echo "[3/3] Smoke tests..."
TOKEN="$(grep PMCC_PROXY_TOKEN /etc/pmcc-proxy.env | cut -d= -f2)"

echo "  /health:"
curl -sS http://localhost:8765/health | python3 -m json.tool

echo
echo "  /spot/SPY:"
curl -sS -H "X-PMCC-Token: $TOKEN" http://localhost:8765/spot/SPY | python3 -m json.tool

echo
echo "  /spot/AAPL:"
curl -sS -H "X-PMCC-Token: $TOKEN" http://localhost:8765/spot/AAPL | python3 -m json.tool

echo
echo "  /account:"
curl -sS -H "X-PMCC-Token: $TOKEN" http://localhost:8765/account | python3 -m json.tool

echo
echo "  /positions:"
curl -sS -H "X-PMCC-Token: $TOKEN" http://localhost:8765/positions | python3 -m json.tool
