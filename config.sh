# Sourced by build.sh and setup.sh. ROOT must be set to this repo.
# config.local is required. Matching environment variables win.

load_identity() {
  if [ ! -f "$ROOT/config.local" ]; then
    echo "Missing config.local. Copy config.example to config.local and set BUNDLE_ID / CODESIGN_IDENTITY." >&2
    exit 1
  fi
  _save_BUNDLE_ID="${BUNDLE_ID+x}"
  _save_BUNDLE_ID_V="${BUNDLE_ID-}"
  _save_APP_DISPLAY_NAME="${APP_DISPLAY_NAME+x}"
  _save_APP_DISPLAY_NAME_V="${APP_DISPLAY_NAME-}"
  _save_APP_BUNDLE="${APP_BUNDLE+x}"
  _save_APP_BUNDLE_V="${APP_BUNDLE-}"
  _save_EXEC="${EXEC+x}"
  _save_EXEC_V="${EXEC-}"
  _save_SERVER_EXEC="${SERVER_EXEC+x}"
  _save_SERVER_EXEC_V="${SERVER_EXEC-}"
  _save_CODESIGN_IDENTITY="${CODESIGN_IDENTITY+x}"
  _save_CODESIGN_IDENTITY_V="${CODESIGN_IDENTITY-}"
  _save_LAUNCHD_LABEL="${LAUNCHD_LABEL+x}"
  _save_LAUNCHD_LABEL_V="${LAUNCHD_LABEL-}"
  _save_SUPPORT_DIR="${SUPPORT_DIR+x}"
  _save_SUPPORT_DIR_V="${SUPPORT_DIR-}"
  _save_LEGACY="${LEGACY_LAUNCHD_LABELS+x}"
  _save_LEGACY_V="${LEGACY_LAUNCHD_LABELS-}"
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1090
  . "$ROOT/config.local"
  set +a
  [ "$_save_BUNDLE_ID" = x ] && BUNDLE_ID="$_save_BUNDLE_ID_V"
  [ "$_save_APP_DISPLAY_NAME" = x ] && APP_DISPLAY_NAME="$_save_APP_DISPLAY_NAME_V"
  [ "$_save_APP_BUNDLE" = x ] && APP_BUNDLE="$_save_APP_BUNDLE_V"
  [ "$_save_EXEC" = x ] && EXEC="$_save_EXEC_V"
  [ "$_save_SERVER_EXEC" = x ] && SERVER_EXEC="$_save_SERVER_EXEC_V"
  [ "$_save_CODESIGN_IDENTITY" = x ] && CODESIGN_IDENTITY="$_save_CODESIGN_IDENTITY_V"
  [ "$_save_LAUNCHD_LABEL" = x ] && LAUNCHD_LABEL="$_save_LAUNCHD_LABEL_V"
  [ "$_save_SUPPORT_DIR" = x ] && SUPPORT_DIR="$_save_SUPPORT_DIR_V"
  [ "$_save_LEGACY" = x ] && LEGACY_LAUNCHD_LABELS="$_save_LEGACY_V"

  : "${BUNDLE_ID:?BUNDLE_ID missing in config.local}"
  : "${APP_DISPLAY_NAME:?APP_DISPLAY_NAME missing in config.local}"
  : "${APP_BUNDLE:?APP_BUNDLE missing in config.local}"
  : "${EXEC:?EXEC missing in config.local}"
  SERVER_EXEC="${SERVER_EXEC:-${EXEC}Server}"
  if [ -z "${LAUNCHD_LABEL}" ]; then
    LAUNCHD_LABEL="${BUNDLE_ID}.mcp"
  fi
  if [ -z "${SUPPORT_DIR}" ]; then
    SUPPORT_DIR="cursor-desktop"
  fi
  MCP_BUNDLE_ID="${BUNDLE_ID}.mcp"
  APP="$ROOT/$APP_BUNDLE"
  HELPER="$APP/Contents/MacOS/$EXEC"
  SERVER_BIN="$APP/Contents/MacOS/$SERVER_EXEC"
}

resolve_codesign_identity() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    return 0
  fi
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
  )"
  if [ -z "${CODESIGN_IDENTITY}" ]; then
    CODESIGN_IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:/ { print $2; exit }'
    )"
  fi
  if [ -z "${CODESIGN_IDENTITY}" ]; then
    echo "No Developer ID / Apple Development identity in the keychain." >&2
    echo "Set CODESIGN_IDENTITY in config.local. Refusing ad-hoc sign (it breaks Accessibility on every rebuild)." >&2
    exit 1
  fi
}
