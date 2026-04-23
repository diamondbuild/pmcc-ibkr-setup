#!/usr/bin/env bash
# Diagnostic + fix for gateway startup failure.
# Locates Gateway install, patches IBC's gatewaystart.sh, re-launches service.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"; exit 1
fi

echo "=================================================="
echo "  Gateway startup diagnostic + fix"
echo "=================================================="

# ---------------------------------------------- 1. Locate Gateway
echo
echo "[1/6] Locating IB Gateway install..."
# Look in all likely locations
CANDIDATES=(
  "/root/Jts/ibgateway"
  "/root/Jts"
  "/opt/ibgateway"
  "/home/*/Jts/ibgateway"
)

GW_BASE=""
GW_VERSION=""
for base in /root/Jts /opt/ibgateway; do
  if [[ -d "$base" ]]; then
    # Look for a directory whose name is a version (e.g. "1037", "10.37", "1019")
    for sub in "$base"/*; do
      [[ -d "$sub" ]] || continue
      name=$(basename "$sub")
      # version dirs contain "jars" subfolder or "ibgateway" script
      if [[ -d "$sub/jars" ]] || [[ -f "$sub/ibgateway" ]] || [[ -d "$sub/install4j" ]]; then
        GW_BASE="$base"
        # Extract numeric version — handle "10.37" → "1037"
        GW_VERSION=$(echo "$name" | tr -d '.' | grep -oE '[0-9]+' | head -1)
        echo "  Found: $sub"
        echo "  Base: $GW_BASE"
        echo "  Version: $GW_VERSION"
        break 2
      fi
    done
  fi
done

if [[ -z "$GW_VERSION" ]]; then
  echo "  ERROR: Couldn't find Gateway install. Listing common paths:"
  ls -la /root/Jts/ 2>/dev/null || echo "  (no /root/Jts)"
  ls -la /opt/ibgateway/ 2>/dev/null || echo "  (no /opt/ibgateway)"
  exit 1
fi

# ---------------------------------------------- 2. Find the actual IB_INI path we wrote
echo
echo "[2/6] Checking IBC config..."
if [[ ! -f /opt/ibc/config.ini ]]; then
  echo "  ERROR: /opt/ibc/config.ini missing. Re-run configure-gateway.sh first."
  exit 1
fi
echo "  Config exists at /opt/ibc/config.ini"

# ---------------------------------------------- 3. Patch gatewaystart.sh properly
echo
echo "[3/6] Patching /opt/ibc/gatewaystart.sh with correct paths + version..."
GW_START=/opt/ibc/gatewaystart.sh

# Back up original if not already
[[ -f "${GW_START}.orig" ]] || cp "$GW_START" "${GW_START}.orig"

# Rewrite just the config lines at the top — matching the exact patterns
# Use awk so we only touch lines that are actually the config vars.
python3 - "$GW_START" "$GW_VERSION" "$GW_BASE" <<'PYEOF'
import re, sys, os
path, version, gw_base = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()

replacements = {
    r"^TWS_MAJOR_VRSN=.*$":    f"TWS_MAJOR_VRSN={version}",
    r"^IBC_INI=.*$":           "IBC_INI=/opt/ibc/config.ini",
    r"^IBC_PATH=.*$":          "IBC_PATH=/opt/ibc",
    r"^TWS_PATH=.*$":          f"TWS_PATH={gw_base}",
    r"^TWS_SETTINGS_PATH=.*$": f"TWS_SETTINGS_PATH={gw_base}",
    r"^LOG_PATH=.*$":          "LOG_PATH=/opt/ibc/logs",
    r"^TRADING_MODE=.*$":      "TRADING_MODE=paper",
    r"^TWOFA_TIMEOUT_ACTION=.*$": "TWOFA_TIMEOUT_ACTION=restart",
}
for pat, new in replacements.items():
    text, n = re.subn(pat, new, text, count=1, flags=re.MULTILINE)
    print(f"  {'patched' if n else 'NOT FOUND'}: {pat} -> {new}")

with open(path, "w") as f:
    f.write(text)
PYEOF

chmod +x "$GW_START"
mkdir -p /opt/ibc/logs

# ---------------------------------------------- 4. Verify the patched script
echo
echo "[4/6] Verifying patched config (top 15 config lines):"
grep -E "^(TWS_MAJOR_VRSN|IBC_INI|IBC_PATH|TWS_PATH|TWS_SETTINGS_PATH|LOG_PATH|TRADING_MODE|TWOFA_TIMEOUT_ACTION)=" "$GW_START"

# ---------------------------------------------- 5. Test run in foreground to see real error
echo
echo "[5/6] Test-running Gateway once (foreground, 15s) to catch errors..."
export DISPLAY=:99
if ! pgrep -x Xvfb >/dev/null; then
  Xvfb :99 -screen 0 1024x768x16 >/dev/null 2>&1 &
  sleep 2
fi
# Run IBC in inline mode, capture output, kill after 15s
timeout 15 /opt/ibc/gatewaystart.sh -inline 2>&1 | head -40 || true
# Kill any lingering java processes from the test run
pkill -f "ibgateway" 2>/dev/null || true
pkill -f "IBController" 2>/dev/null || true
pkill -f "IBC" 2>/dev/null || true
sleep 2

# ---------------------------------------------- 6. Restart via systemd
echo
echo "[6/6] Restarting systemd service..."
systemctl restart pmcc-gateway.service
sleep 30

# Check if it survived the restart
echo
echo "Gateway service status:"
systemctl status pmcc-gateway.service --no-pager -l | head -15

echo
echo "Recent gateway logs:"
journalctl -u pmcc-gateway.service -n 25 --no-pager | tail -25

# Restart proxy and check health
echo
systemctl restart pmcc-proxy.service
sleep 5
echo "--- Proxy health ---"
curl -sS http://localhost:8765/health | python3 -m json.tool || true
echo
echo "Done. If gateway_connected is still false, paste the gateway logs above to chat."
