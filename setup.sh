#!/bin/sh
# Trigger macOS prompts for this signed app. TCC cannot be granted from a script.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/config.sh"
load_identity
cd "$ROOT"
"$ROOT/build.sh"

cat <<EOF
macOS will not let setup silently pre-authorize anything. Enable these
rows for ${APP_DISPLAY_NAME} (the signed .app, not Cursor):

  Required
    • Accessibilité          — sheet has no Autoriser; toggle in Réglages
    • Enregistrement de l’écran

  Not used
    • Automatisation → System Events
    • Surveillance des entrées (Input Monitoring)
    • Accès complet au disque
    • Gestion des apps / données d’autres apps

After toggling, quit leftover ${APP_DISPLAY_NAME} processes if any.
Grants apply to that one resident helper; MCP talks to it over a unix socket
(not a new \`open -n\` per click — that re-prompts Accessibility on Sequoia).
EOF

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
open -R "$APP"
SOCK="$HOME/Library/Application Support/${SUPPORT_DIR}/helper.sock"
mkdir -p "$(dirname "$SOCK")"
open -n -a "$APP" --args serve --socket "$SOCK"
echo "setup: opened Settings + started one resident helper (serve)"

UID_NUM="$(id -u)"
PLIST_DST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
mkdir -p "$HOME/Library/LaunchAgents"

export ROOT LAUNCHD_LABEL BUNDLE_ID SERVER_BIN
python3 - <<'PY'
import os
from pathlib import Path
from xml.sax.saxutils import escape

root = os.environ["ROOT"]
label = os.environ["LAUNCHD_LABEL"]
bundle = os.environ["BUNDLE_ID"]
server = os.environ["SERVER_BIN"]
dst = Path.home() / "Library/LaunchAgents" / (label + ".plist")
dst.write_text(
    """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>%s</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>2</integer>
  <key>WorkingDirectory</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/cua-mcp-http.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/cua-mcp-http.log</string>
</dict>
</plist>
"""
    % (escape(label), escape(bundle), escape(root), escape(server)),
    encoding="utf-8",
)
print("wrote", dst)
PY

launchctl bootout "gui/${UID_NUM}/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
for lbl in $LEGACY_LAUNCHD_LABELS; do
  [ -n "$lbl" ] || continue
  launchctl bootout "gui/${UID_NUM}/${lbl}" >/dev/null 2>&1 || true
done
if launchctl print "gui/${UID_NUM}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/${UID_NUM}/${LAUNCHD_LABEL}"
else
  launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DST"
  launchctl kickstart -k "gui/${UID_NUM}/${LAUNCHD_LABEL}"
fi
echo "setup: HTTP MCP is ${APP_DISPLAY_NAME} Server (LaunchAgent, 127.0.0.1:8765/mcp)"
