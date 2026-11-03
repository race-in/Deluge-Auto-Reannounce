#!/usr/bin/env bash
# Rootless installer for Feral Hosting / Deluge 1.3.15 shared slots.
set -euo pipefail

VERSION="1.0.0-feral"
APP="deluge-auto-reannounce"
BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APP"
BIN_DIR="${HOME}/.local/bin"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say(){ printf '[%s] %s\n' "$1" "$2"; }
die(){ say ERROR "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as the Feral slot user, not root."
command -v bash >/dev/null 2>&1 || die "bash is required"
PYTHON_BIN="${DELUGE_PYTHON:-}"
if [ -z "$PYTHON_BIN" ]; then
    for candidate in "$HOME/bin/python2.7" "$HOME/.local/bin/python2.7" "$(command -v python2.7 2>/dev/null || true)" "$(command -v python 2>/dev/null || true)" "$(command -v python3 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then PYTHON_BIN="$candidate"; break; fi
    done
fi
[ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] || die "Python interpreter not found. Set DELUGE_PYTHON=/path/to/deluge-python."
command -v install >/dev/null 2>&1 || die "install is required"

find_console() {
    if [ -n "${DELUGE_CONSOLE:-}" ] && [ -x "$DELUGE_CONSOLE" ]; then printf '%s\n' "$DELUGE_CONSOLE"; return; fi
    for candidate in "$HOME/bin/deluge-console" "$HOME/.local/bin/deluge-console" "$(command -v deluge-console 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return; }
    done
    return 1
}

CONSOLE=$(find_console) || die "deluge-console not found. Set DELUGE_CONSOLE=/full/path/to/deluge-console and rerun."
VERSION_TEXT=$("$CONSOLE" --version 2>&1 | head -n 1 || true)
case "$VERSION_TEXT" in *1.3.15*) ;; *) say WARNING "Expected Deluge 1.3.15; detected: ${VERSION_TEXT:-unknown}. Continuing, but compatibility is not guaranteed.";; esac

CORE_CONF="${DELUGE_CONFIG_DIR:-$HOME/.config/deluge}/core.conf"
PORT=${DELUGE_PORT:-}
if [ -z "$PORT" ] && [ -r "$CORE_CONF" ]; then
    PORT=$("$PYTHON_BIN" - "$CORE_CONF" <<'PY'
import json,sys
try:
    with open(sys.argv[1]) as f: data=json.load(f)
    print(data.get('daemon_port',''))
except Exception:
    pass
PY
)
fi
PORT=${PORT:-58846}
case "$PORT" in *[!0-9]*|'') die "Invalid Deluge daemon port";; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "Deluge daemon port out of range"

[ -s "$SOURCE_DIR/scripts/reannounce-new.sh" ] || die "Missing scripts/reannounce-new.sh; run installer from repository checkout"
[ -s "$SOURCE_DIR/scripts/configure-execute.py" ] || die "Missing scripts/configure-execute.py"

mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"

config="$CONFIG_DIR/reannounce.conf"
if [ ! -e "$config" ]; then
cat > "$config" <<EOF2
DELUGE_CONSOLE="$CONSOLE"
DELUGE_HOST="${DELUGE_HOST:-127.0.0.1}"
DELUGE_PORT="$PORT"
INITIAL_DELAY="${INITIAL_DELAY:-0.5}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"
MAX_RUNTIME="${MAX_RUNTIME:-300}"
REANNOUNCE_INTERVAL="${REANNOUNCE_INTERVAL:-30}"
SENT_TIMEOUT="${SENT_TIMEOUT:-15}"
LOG_FILE="$STATE_DIR/reannounce.log"
EOF2
else
    cp "$config" "$config.backup.$(date +%Y%m%d-%H%M%S)"
    grep -q '^DELUGE_CONSOLE=' "$config" || printf '\nDELUGE_CONSOLE="%s"\n' "$CONSOLE" >> "$config"
fi
chmod 600 "$config"

install -m 755 "$SOURCE_DIR/scripts/reannounce-new.sh" "$BASE_DIR/reannounce-new.sh"

cat > "$BASE_DIR/execute-reannounce.sh" <<EOF2
#!/usr/bin/env bash
set -a
. "$config"
set +a
exec "$BASE_DIR/reannounce-new.sh" "\$@"
EOF2
chmod 700 "$BASE_DIR/execute-reannounce.sh"

cat > "$BIN_DIR/deluge-reannounce" <<EOF2
#!/usr/bin/env bash
set -a
. "$config"
set +a
exec "\$DELUGE_CONSOLE" "connect \$DELUGE_HOST:\$DELUGE_PORT; reannounce \${1:?Usage: deluge-reannounce TORRENT_HASH}"
EOF2
chmod 700 "$BIN_DIR/deluge-reannounce"

if "$PYTHON_BIN" -c 'import deluge.ui.client, twisted.internet' >/dev/null 2>&1; then
    if ! DELUGE_HOST="${DELUGE_HOST:-127.0.0.1}" "$PYTHON_BIN" "$SOURCE_DIR/scripts/configure-execute.py" "$PORT" "$BASE_DIR/execute-reannounce.sh"; then
        say WARNING "Automatic Execute RPC registration failed. Add Torrent Added event manually (see README)."
    fi
else
    say WARNING "Current python cannot import Deluge/Twisted; skipping automatic Execute registration. Set DELUGE_PYTHON to Deluge's own Python and see README."
fi

echo
say OK "Feral rootless installation complete ($VERSION)"
printf 'Deluge console : %s\nDaemon         : 127.0.0.1:%s\nInstall dir    : %s\nConfig         : %s\nLog            : %s/reannounce.log\nExecute wrapper: %s/execute-reannounce.sh\n' "$CONSOLE" "$PORT" "$BASE_DIR" "$config" "$STATE_DIR" "$BASE_DIR"
printf '\nAdd this in Deluge WebUI: Preferences → Execute → Torrent Added → %s/execute-reannounce.sh\n' "$BASE_DIR"
printf 'Python used for detection/RPC: %s\n' "$PYTHON_BIN"
printf 'Ensure ~/.local/bin is in PATH for deluge-reannounce.\n'
