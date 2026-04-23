#!/usr/bin/env bash
# Fix: install system libraries that IB Gateway's bundled Java AWT needs.
# Ubuntu 24.04 minimal droplets ship without fontconfig/freetype/libXtst/etc.
# which causes: java.lang.UnsatisfiedLinkError in Toolkit.loadLibraries.
set -e
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[0/6] Showing the exact Java error first..."
head -120 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt 2>/dev/null \
  | grep -E "Error|Exception|library|cannot|no .* in java.library.path|UnsatisfiedLinkError" \
  | head -20 || echo "  (no prior error lines matched)"

echo
echo "[1/6] Stopping gateway + killing zombies..."
systemctl stop pmcc-gateway.service 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f ibgateway 2>/dev/null || true
pkill -9 -f 'java.*IBC' 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
sleep 2

echo
echo "[2/6] Installing missing X11 + font libraries for headless AWT..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  libxtst6 libxrender1 libxi6 libxrandr2 libxcursor1 libxcomposite1 libxdamage1 \
  libxext6 libxfixes3 libxft2 libxmu6 \
  libfontconfig1 libfreetype6 \
  fontconfig fonts-dejavu \
  libcups2 libasound2t64 2>/dev/null || apt-get install -y -qq \
  libxtst6 libxrender1 libxi6 libxrandr2 libxcursor1 libxcomposite1 libxdamage1 \
  libxext6 libxfixes3 libxft2 libxmu6 \
  libfontconfig1 libfreetype6 \
  fontconfig fonts-dejavu \
  libcups2 libasound2
echo "  System libs installed."

echo
echo "[3/6] Verifying libXtst is visible to Gateway's bundled JRE..."
JRE_BIN=$(ls -d /opt/i4j_jres/*/bin 2>/dev/null | head -1)
if [[ -n "$JRE_BIN" ]]; then
  echo "  Bundled JRE: $JRE_BIN"
  JAVA_BIN="$JRE_BIN/java"
  "$JAVA_BIN" -version 2>&1 | head -3 || true
else
  echo "  WARN: bundled JRE not found"
fi
ldconfig
echo "  libXtst.so.6: $(ldconfig -p | grep libXtst.so.6 | head -1)"
echo "  libfontconfig.so.1: $(ldconfig -p | grep libfontconfig.so.1 | head -1)"

echo
echo "[4/6] Quick headless AWT self-test (bundled Java)..."
if [[ -n "$JRE_BIN" ]]; then
  cat > /tmp/AwtTest.java <<'JAVA'
public class AwtTest {
  public static void main(String[] a) {
    System.setProperty("java.awt.headless", "false");
    java.awt.Toolkit.getDefaultToolkit();
    System.out.println("AWT OK");
  }
}
JAVA
  # Use javac if present, otherwise skip
  JAVAC="$JRE_BIN/javac"
  if [[ -x "$JAVAC" ]]; then
    (cd /tmp && "$JAVAC" AwtTest.java 2>&1 | head -5) || true
    (cd /tmp && DISPLAY= "$JRE_BIN/java" -Djava.awt.headless=true AwtTest 2>&1 | head -5) || true
  fi
  # Start a scratch Xvfb and try non-headless
  rm -f /tmp/.X99-lock
  Xvfb :99 -screen 0 1024x768x16 >/dev/null 2>&1 &
  TEST_XVFB=$!
  sleep 2
  if [[ -x "$JAVAC" ]] && [[ -f /tmp/AwtTest.class ]]; then
    echo "  Non-headless AWT test on :99..."
    DISPLAY=:99 "$JRE_BIN/java" -cp /tmp AwtTest 2>&1 | head -10 || echo "  (AWT still failing - see above)"
  fi
  kill $TEST_XVFB 2>/dev/null || true
  sleep 1
  rm -f /tmp/.X99-lock
fi

echo
echo "[5/6] Starting gateway service fresh..."
systemctl start pmcc-gateway.service
for i in $(seq 1 18); do
  sleep 5
  status=$(systemctl is-active pmcc-gateway.service)
  printf "  [%02d/18] service: %s\n" $i "$status"
  if [[ "$status" != "active" ]] && [[ "$status" != "activating" ]]; then
    echo "  Service died (status: $status)."
    break
  fi
done

echo
echo "Gateway service status:"
systemctl status pmcc-gateway.service --no-pager -l | head -14

echo
echo "Latest 40 log lines:"
journalctl -u pmcc-gateway.service -n 40 --no-pager | tail -40

echo
echo "[6/6] Restart proxy + health check..."
systemctl restart pmcc-proxy.service
sleep 5
curl -sS http://localhost:8765/health | python3 -m json.tool || echo "(proxy not responding)"

echo
echo "If still disconnected, check IBC log for the next error:"
echo "  tail -80 /opt/ibc/logs/ibc-3.20.0_GATEWAY-1037_Thursday.txt"
