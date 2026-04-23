#!/usr/bin/env bash
# Add 2GB swap to prevent OOM, then enumerate all windows (including hidden)
# and attempt to auto-dismiss the stuck "Gateway" dialog with OK/Yes.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/6] Adding 2GB swap file (one-time)..."
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10 >/dev/null
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
  echo "  Swap created: $(free -h | awk '/Swap:/ {print $2}')"
else
  swapon /swapfile 2>/dev/null || true
  echo "  Swap already present: $(free -h | awk '/Swap:/ {print $2}')"
fi

echo
echo "[2/6] Memory status:"
free -h

echo
echo "[3/6] Reducing Gateway Java heap from 768M to 512M (less OOM risk)..."
GSS=/opt/ibgateway/ibgateway.vmoptions
for f in /opt/ibgateway/ibgateway.vmoptions /root/Jts/ibgateway/1037/ibgateway.vmoptions; do
  if [[ -f "$f" ]]; then
    sed -i 's/-Xmx[0-9]\+m/-Xmx512m/' "$f" 2>/dev/null || true
    echo "  Patched: $f"
  fi
done
# Also write a Gateway heap override file IBC will pick up
cat > /root/Jts/ibgateway_vmoptions_override.vmoptions <<'VM'
-Xmx512m
-XX:+UseG1GC
VM

echo
echo "[4/6] Restarting gateway service (with swap + smaller heap)..."
systemctl restart pmcc-gateway.service
echo "  Waiting 60s for IBKR login..."
for i in $(seq 1 12); do
  sleep 5
  status=$(systemctl is-active pmcc-gateway.service)
  printf "  [%02d/12] service: %s  mem: %s\n" $i "$status" "$(free -m | awk '/Mem:/ {print $3"M used"}')"
  if [[ "$status" != "active" ]] && [[ "$status" != "activating" ]]; then
    break
  fi
done

echo
echo "[5/6] Enumerate ALL windows (including hidden/minimized)..."
export DISPLAY=:99

echo "  -- xdotool search all (not just visible) --"
xdotool search --name "" 2>/dev/null | while read wid; do
  name=$(xdotool getwindowname $wid 2>/dev/null || echo "?")
  echo "    wid=$wid  name=\"$name\""
done | head -30

echo
echo "  -- xwininfo tree --"
xwininfo -root -tree -display :99 2>&1 | grep -v '^ *$' | head -40 || true

echo
echo "  -- Try to auto-accept the stuck 'Gateway' dialog --"
# The dialog titled "Gateway" is likely the API acceptance prompt or a notice.
# Try clicking common buttons.
for btn in "OK" "Yes" "I Agree" "Accept" "Continue" "Close"; do
  wid=$(xdotool search --name "^Gateway$" 2>/dev/null | head -1)
  if [[ -n "$wid" ]]; then
    xdotool windowactivate $wid 2>/dev/null || true
    xdotool key --window $wid Return 2>/dev/null && echo "    Sent Return to wid=$wid" || true
    break
  fi
done

echo
echo "[6/6] Final check..."
sleep 3
echo "  -- Log tail --"
tail -15 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt
echo
echo "  -- Port 4002 --"
ss -tlnp | grep 4002 || echo "    (not listening)"
echo
echo "  -- Health --"
curl -sS http://localhost:8765/health
echo
echo
echo "If still disconnected, wait 30s then: curl -sS http://localhost:8765/health"
echo "Memory now: $(free -h | awk '/Mem:/ {print $3\"/\"$2}')"
