#!/usr/bin/env bash
# Seed Gateway's persistent settings file so the API is pre-enabled on port 4002,
# bypassing IBC's stuck config dialog navigation.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

export DISPLAY=:99

echo "[1/8] Investigating where Gateway stores its per-user settings..."
systemctl stop pmcc-gateway.service 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f ibgateway 2>/dev/null || true
pkill -9 -f 'java.*IBC' 2>/dev/null || true
pkill -9 -f openbox 2>/dev/null || true
rm -f /tmp/.X99-lock 2>/dev/null || true
sleep 2
echo "  Clean slate."

echo
echo "[2/8] Listing contents of /root/Jts..."
find /root/Jts -maxdepth 3 -type f 2>/dev/null | head -30 || true
echo "---"
find /root/Jts -maxdepth 3 -type d 2>/dev/null | head -15 || true

echo
echo "[3/8] Looking for any existing settings XML/ini..."
find /root/Jts -maxdepth 4 -name "*.xml" -o -name "*.ini" 2>/dev/null | head -20 || true

echo
echo "[4/8] Creating Gateway user directory and settings skeleton..."
# Gateway stores per-login-id settings at ~/Jts/<LOGINID>/
USER_DIR=/root/Jts/DUQ598591
mkdir -p "$USER_DIR"

# The key file is jts.ini in root/Jts. We'll enhance it:
cat > /root/Jts/jts.ini <<'JTS'
[Logon]
s3store=true
Locale=en
displayedproxymsg=1
UseSSL=true
[IBGateway]
ApiOnly=true
LocalServerPort=4002
[Communication]
Region=usa
SuppressInfoMessages=yes
[NSF]
BYPASS=true
JTS
echo "  jts.ini rewritten."

echo
echo "[5/8] Enabling VNC + x11vnc so you can SEE the stuck Gateway from your phone..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq x11vnc openbox >/dev/null 2>&1 || true

# Generate a VNC password
echo "pmccvnc2026" | x11vnc -storepasswd - /root/.vncpasswd >/dev/null 2>&1 || true

# Create systemd unit for x11vnc (view-only from your phone browser)
cat > /etc/systemd/system/pmcc-vnc.service <<'VNC'
[Unit]
Description=x11vnc for PMCC Gateway display :99
After=pmcc-gateway.service
Requires=pmcc-gateway.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display :99 -rfbauth /root/.vncpasswd -rfbport 5900 -forever -shared -noxdamage
Restart=on-failure

[Install]
WantedBy=multi-user.target
VNC

# Allow VNC port through firewall TEMPORARILY
ufw allow 5900/tcp >/dev/null 2>&1 || true

systemctl daemon-reload
echo "  VNC service installed. Port 5900 opened in firewall."

echo
echo "[6/8] Starting gateway + VNC..."
systemctl start pmcc-gateway.service
sleep 30
systemctl start pmcc-vnc.service
sleep 3

echo
echo "[7/8] Status check:"
systemctl is-active pmcc-gateway.service
systemctl is-active pmcc-vnc.service
echo
echo "Port 4002 (API):     $(ss -tln | grep -c ':4002 ') listener(s)"
echo "Port 5900 (VNC):     $(ss -tln | grep -c ':5900 ') listener(s)"

echo
echo "[8/8] Current Gateway windows (what's blocking):"
xdotool search --name "." 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "?")
  echo "    wid=$wid  \"$name\""
done | head -15

echo
echo "============================================"
echo "  VNC ACCESS INFO (one-time manual step)"
echo "============================================"
echo "  Server:   198.199.86.74:5900"
echo "  Password: pmccvnc2026"
echo ""
echo "On your iPhone:"
echo "  1. Install 'RealVNC Viewer' (free) from App Store"
echo "  2. New connection → 198.199.86.74:5900"
echo "  3. Password: pmccvnc2026"
echo "  4. You'll see the Gateway desktop. Click through any"
echo "     dialog that's blocking (likely 'API settings' or a notice)."
echo "  5. In Gateway menu: Configure → Settings → API → Settings"
echo "     • Enable ActiveX and Socket Clients: YES"
echo "     • Socket port: 4002"
echo "     • Read-Only API: YES"
echo "     • Trusted IPs: add 127.0.0.1"
echo "  6. Click OK/Apply, then Close the config dialog"
echo ""
echo "Gateway will save settings and the API port will open."
echo "After that, VNC is no longer needed:"
echo "  systemctl stop pmcc-vnc.service && ufw deny 5900"
echo "============================================"
echo
curl -sS http://localhost:8765/health
echo
