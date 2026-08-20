#!/bin/bash
# Interactive setup for the Claude Code CGM status line segment.
# The password is typed straight into the macOS Keychain: it is never written to
# a file, never passed as a command argument (so it cannot show up in `ps`), and
# never enters shell history.
set -e
CGM="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SERVICE=claude-cgm-dexcom

if [ ! -t 0 ]; then
  echo "setup.sh needs a terminal to prompt for the password."
  echo "Run it from Terminal.app, or use ~/.claude/cgm/verify-start.sh instead."
  exit 1
fi

echo "Dexcom Share setup"
echo "------------------"
echo "Use HIS Dexcom account (the sharer), NOT your Follow login."
echo "Share must already have at least one follower configured."
echo

PREV_USER=$(jq -r '.username // ""' "$CGM/config.json" 2>/dev/null)
PREV_REGION=$(jq -r '.region // "ous"' "$CGM/config.json" 2>/dev/null)
case "$PREV_USER" in REPLACE_WITH_*) PREV_USER="";; esac

read -r -p "His Dexcom username / email / phone${PREV_USER:+ [$PREV_USER]}: " USERNAME
USERNAME=${USERNAME:-$PREV_USER}
[ -n "$USERNAME" ] || { echo "empty username, aborting"; exit 1; }

read -r -p "Region [${PREV_REGION:-ous}]: " REGION
REGION=${REGION:-${PREV_REGION:-ous}}
case "$REGION" in us|ous|jp) ;; *) echo "region must be us, ous or jp"; exit 1;; esac

cat > "$CGM/config.json" <<JSON
{
  "username": "$USERNAME",
  "region": "$REGION",
  "keychain_service": "$SERVICE"
}
JSON
chmod 600 "$CGM/config.json"
echo "wrote $CGM/config.json (no password in it)"
echo

echo "Now the password. 'security' will prompt you twice; nothing is echoed."
security add-generic-password -U -s "$SERVICE" -a "$USERNAME" -w
echo "stored in Keychain under service=$SERVICE account=$USERNAME"
echo

echo "Testing the credentials against Dexcom..."
if CGM_DIR="$CGM" "$CGM/venv/bin/python" - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
from pydexcom import Dexcom, Region
from pydexcom.errors import DexcomError

cfg = json.loads((Path(os.environ["CGM_DIR"])/"config.json").read_text())
pw = subprocess.run(["security","find-generic-password","-s",cfg["keychain_service"],
                     "-a",cfg["username"],"-w"], capture_output=True, text=True).stdout.strip()
try:
    d = Dexcom(username=cfg["username"], password=pw, region=Region(cfg["region"]))
    r = d.get_current_glucose_reading()
except DexcomError as e:
    print(f"  FAILED: {e}")
    print("  Check: sharer account (not Follow), correct region, Share has a follower.")
    sys.exit(1)
if r is None:
    print("  Login OK, but no reading in the last 10 min (sensor warmup or no upload).")
else:
    print(f"  OK: {r.value} mg/dL {r.trend_arrow} ({r.trend_description}) at {r.datetime}")
PY
then
  echo
  echo "Starting the poller..."
  launchctl unload "$HOME/Library/LaunchAgents/com.claude-cgm.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.claude-cgm.plist"
  echo "Done. It will appear in the Claude Code status line within a minute or two."
  echo "Log: tail -f $CGM/cgm.log"
else
  echo
  echo "Not starting the poller until the credentials work."
  exit 1
fi
