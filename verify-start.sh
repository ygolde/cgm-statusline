#!/bin/bash
# Verify the stored Dexcom credentials and start the poller. No prompts:
# safe to run from Claude Code's `!` bash mode.
set -e
CGM="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLIST="$HOME/Library/LaunchAgents/com.claude-cgm.plist"

USERNAME=$(jq -r '.username' "$CGM/config.json")
SERVICE=$(jq -r '.keychain_service' "$CGM/config.json")
REGION=$(jq -r '.region' "$CGM/config.json")
echo "config: user=$USERNAME region=$REGION"

if ! security find-generic-password -s "$SERVICE" -a "$USERNAME" -w >/dev/null 2>&1; then
  echo
  echo "No password in the Keychain yet. Run this in Terminal.app (it prompts):"
  echo
  echo "  security add-generic-password -U -s $SERVICE -a $USERNAME -w"
  echo
  echo "Then re-run: ~/.claude/cgm/verify-start.sh"
  exit 1
fi
echo "keychain: password found"
echo
echo "Testing against Dexcom..."
CGM_DIR="$CGM" "$CGM/venv/bin/python" - <<'PY' || exit 1
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
    print("  Likely: Follow account instead of the sharer's, wrong region,")
    print("  or Share has no follower configured.")
    sys.exit(1)
print(f"  OK: {r.value} mg/dL {r.trend_arrow} ({r.trend_description}) at {r.datetime}"
      if r else "  Login OK, but no reading in the last 10 min (warmup / not uploading).")
PY
echo
echo "Starting poller..."
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 3
launchctl list | grep claude-cgm || true
echo "Log: tail -f $CGM/cgm.log"
