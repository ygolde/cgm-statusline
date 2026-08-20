#!/bin/bash
# Install the CGM status line: venv, launchd agent, Claude Code settings.
# Credentials are handled separately by ./setup.sh (they go to the Keychain).
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLIST="$HOME/Library/LaunchAgents/com.claude-cgm.plist"

command -v jq >/dev/null || { echo "jq is required: brew install jq"; exit 1; }

echo "1/4 python venv + pydexcom"
[ -d "$DIR/venv" ] || python3 -m venv "$DIR/venv"
"$DIR/venv/bin/pip" -q install --upgrade pip
"$DIR/venv/bin/pip" -q install "pydexcom==0.5.1"

echo "2/4 config"
[ -f "$DIR/config.json" ] || { cp "$DIR/config.example.json" "$DIR/config.json"
  chmod 600 "$DIR/config.json"; echo "    created config.json - edit username + region"; }

echo "3/4 launchd agent"
sed "s|__DIR__|$DIR|g" "$DIR/com.claude-cgm.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "4/4 Claude Code status line"
S="$HOME/.claude/settings.json"
[ -f "$S" ] || echo '{}' > "$S"
python3 - "$S" "$DIR" <<'PY'
import json, sys
p, d = sys.argv[1], sys.argv[2]
s = json.load(open(p))
s["statusLine"] = {"type":"command","command":f"{d}/statusline.sh",
                   "padding":0,"refreshInterval":30}
json.dump(s, open(p,"w"), indent=2); open(p,"a").write("\n")
PY

echo
echo "Done. Next:"
echo "  1. edit $DIR/config.json  (username, region: us|ous|jp)"
echo "  2. run $DIR/setup.sh      (stores the password in the Keychain, tests, starts)"
