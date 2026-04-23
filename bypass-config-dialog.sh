#!/usr/bin/env bash
# Pre-configure Gateway settings so IBC doesn't need to open the config dialog.
# Writes API settings directly to jts.ini + the Gateway settings XML.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

export DISPLAY=:99

echo "[1/7] Stopping gateway cleanly..."
systemctl stop pmcc-gateway.service 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f ibgateway 2>/dev/null || true
pkill -9 -f 'java.*IBC' 2>/dev/null || true
pkill -9 -f openbox 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
sleep 2
echo "  Clean."

echo
echo "[2/7] Writing complete jts.ini with API enabled..."
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
JTS
echo "  jts.ini written."

echo
echo "[3/7] Pre-populating Gateway user settings (so API dialog is pre-accepted)..."
# IB Gateway stores per-user settings at ~/Jts/<username>/
# After first login, user settings land at: /root/Jts/DUQ598591/jts.settings.xml (roughly)
# We create a minimal settings.xml that opens the API port immediately.
mkdir -p /root/Jts/DUQ598591 2>/dev/null || true

# Gateway 10.x writes its config to files named like xyz.xml under ~/Jts/<user>/
# We can't easily fabricate these, but we CAN pass API settings as JVM props.
# Most reliable: tell IBC to NOT auto-open the config dialog.

echo "  Skipped (we'll force API port via IBC settings instead)."

echo
echo "[4/7] Rewriting /opt/ibc/config.ini with all known API-related keys..."
PW="Tr@in8181295"
cat > /opt/ibc/config.ini <<CFG
# IBC config for PMCC paper Gateway
IbLoginId=DUQ598591
IbPassword=$PW
TradingMode=paper
FIX=no
IbDir=/root/Jts
StoreSettingsOnServer=no

# Login handling
LoginDialogDisplayTimeout=60
MinimizeMainWindow=yes
ExistingSessionDetectedAction=primary
AcceptNonBrokerageAccountWarning=yes
AcceptBidAskLastSizeDisplayUpdateNotification=accept

# API settings - the critical ones
ReadOnlyApi=yes
AcceptIncomingConnectionAction=accept
ShowAllTrades=no
OverrideTwsApiPort=4002
SendMarketDataInLotsForUSstocks=no
SuppressInfoMessages=yes

# 2FA
SecondFactorAuthenticationExitInterval=40
ReloginAfterSecondFactorAuthenticationTimeout=yes
AutoRestartTimeOfDay=

# Disable auto-logoff
AutoLogoffDisabled=yes

# Java bug workaround (Java 17 / Swing LAF)
# no-op here but IBC will read it

# Disable bid/ask notification
AllowBlindTrading=yes
DismissPasswordExpiryWarning=yes
DismissNSEComplianceNotice=yes
CFG
echo "  config.ini written."

echo
echo "[5/7] Installing openbox so xdotool clicks work cleanly..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openbox >/dev/null 2>&1 || true

# Make systemd unit launch openbox alongside Xvfb
cat > /opt/ibc/run-gateway-wrapped.sh <<'WRAPPER'
#!/usr/bin/env bash
set -e
rm -f /tmp/.X99-lock 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x16 >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=:99
sleep 3
# Start a lightweight WM so AWT focus works correctly
if command -v openbox >/dev/null 2>&1; then
  openbox --sm-disable >/tmp/openbox.log 2>&1 &
  OB_PID=$!
  sleep 1
fi
trap "kill -TERM $XVFB_PID $OB_PID 2>/dev/null; pkill -f ibgateway 2>/dev/null; exit 0" TERM INT
exec /opt/ibc/gatewaystart.sh -inline
WRAPPER
chmod +x /opt/ibc/run-gateway-wrapped.sh
echo "  Wrapper updated (now launches openbox)."

echo
echo "[6/7] Starting gateway service..."
systemctl start pmcc-gateway.service

echo "  Waiting 100s for login + API port..."
OPENED=0
for i in $(seq 1 20); do
  sleep 5
  status=$(systemctl is-active pmcc-gateway.service)
  port_up=$(ss -tln | grep -c ':4002 ' || true)
  printf "  [%02d/20] service:%s  port4002:%s  mem:%s\n" $i "$status" "$port_up" "$(free -m | awk '/Mem:/ {print $3}')M"
  if [[ "$port_up" -gt 0 ]]; then
    OPENED=1
    echo "  🎉 PORT 4002 IS OPEN!"
    break
  fi
  if [[ "$status" != "active" ]] && [[ "$status" != "activating" ]]; then
    echo "  Service died."
    break
  fi
done

echo
echo "[7/7] Results..."
echo "  IBC log (last 20):"
tail -20 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt
echo
echo "  Port status:"
ss -tln | grep 4002 || echo "    (still not listening)"
echo
echo "  Windows currently on display:"
xdotool search --name "." 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "?")
  echo "    wid=$wid  \"$name\""
done | head -15
echo
echo "  Restarting proxy and checking health..."
systemctl restart pmcc-proxy.service
sleep 5
curl -sS http://localhost:8765/health
echo
