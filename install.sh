#!/usr/bin/env bash
# PMCC Radar — IBKR VPS installer
# Sets up: Java, IB Gateway, Python venv, FastAPI proxy, systemd services
# Safe to re-run; idempotent.
set -euo pipefail

echo "=================================================="
echo "  PMCC Radar IBKR Gateway installer"
echo "=================================================="
echo

# -------------------------------------------------- Preflight
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

# -------------------------------------------------- System packages
echo "[1/6] Updating system + installing base packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl wget unzip git \
  openjdk-17-jre-headless \
  python3 python3-venv python3-pip \
  ufw \
  xvfb xauth \
  >/dev/null

# -------------------------------------------------- Firewall (read-only API, only we talk to it)
echo "[2/6] Configuring firewall (SSH + proxy port only)..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 8765/tcp comment 'PMCC proxy' >/dev/null
ufw --force enable >/dev/null

# -------------------------------------------------- IBC (IBKR Gateway controller)
# IBC starts IB Gateway headlessly and handles the daily auto-logoff.
echo "[3/6] Installing IB Gateway + IBC..."
mkdir -p /opt/ibkr
cd /opt/ibkr

# IB Gateway stable
if [[ ! -f /opt/ibkr/ibgateway/jts.ini ]] && [[ ! -d /root/Jts ]]; then
  wget -q -O ibgateway-latest-standalone-linux-x64.sh \
    https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh
  chmod +x ibgateway-latest-standalone-linux-x64.sh
  # Headless install to /root/Jts/ibgateway/<ver>
  echo "  Installing Gateway silently (accepting license)..."
  (echo "o"; echo "1"; echo "n"; echo "") | ./ibgateway-latest-standalone-linux-x64.sh -q || true
fi

# IBC — opensource tool that auto-logs-in Gateway and keeps it alive
IBC_VER="3.20.0"
if [[ ! -d /opt/ibc ]]; then
  mkdir -p /opt/ibc && cd /opt/ibc
  wget -q -O IBCLinux.zip \
    "https://github.com/IbcAlpha/IBC/releases/download/${IBC_VER}/IBCLinux-${IBC_VER}.zip"
  unzip -q -o IBCLinux.zip
  chmod +x *.sh
fi

# -------------------------------------------------- PMCC proxy service
echo "[4/6] Installing PMCC proxy..."
PROXY_DIR=/opt/pmcc-proxy
mkdir -p "$PROXY_DIR"
cd "$PROXY_DIR"

python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q \
  fastapi==0.115.0 \
  uvicorn[standard]==0.30.6 \
  ib_insync==0.9.86 \
  pandas==2.2.2 \
  numpy==1.26.4

# Fetch the proxy code from this repo
curl -fsSL -o proxy.py \
  https://raw.githubusercontent.com/diamondbuild/pmcc-ibkr-setup/main/proxy.py

# Generate a random shared-secret token (only our Streamlit app will know it)
if [[ ! -f /etc/pmcc-proxy.env ]]; then
  TOKEN=$(openssl rand -hex 32)
  cat > /etc/pmcc-proxy.env <<EOF
PMCC_PROXY_TOKEN=$TOKEN
IB_HOST=127.0.0.1
IB_PORT=4002
IB_CLIENT_ID=17
EOF
  chmod 600 /etc/pmcc-proxy.env
fi

# -------------------------------------------------- systemd services
echo "[5/6] Configuring systemd services..."

cat > /etc/systemd/system/pmcc-proxy.service <<'UNIT'
[Unit]
Description=PMCC Radar IBKR Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pmcc-proxy
EnvironmentFile=/etc/pmcc-proxy.env
ExecStart=/opt/pmcc-proxy/venv/bin/uvicorn proxy:app --host 0.0.0.0 --port 8765
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pmcc-proxy.service >/dev/null
systemctl restart pmcc-proxy.service || true

# -------------------------------------------------- Summary
echo "[6/6] Done!"
echo
echo "=================================================="
echo "  Setup complete"
echo "=================================================="
echo
echo "Proxy is running on port 8765."
echo "Your private API token:"
echo
grep PMCC_PROXY_TOKEN /etc/pmcc-proxy.env | cut -d= -f2
echo
echo "SAVE THIS TOKEN — you'll give it to the Streamlit app later."
echo
echo "Next steps (we'll walk through these together):"
echo "  1. Configure IBC with your IBKR paper login"
echo "  2. Start IB Gateway via IBC"
echo "  3. Test the proxy from your laptop/phone"
echo
echo "To check the proxy is up:"
echo "  curl http://localhost:8765/health"
echo
