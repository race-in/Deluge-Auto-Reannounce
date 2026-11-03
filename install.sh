#!/usr/bin/env bash
# Rootless installer for Feral Hosting / Deluge 1.3.15 shared slots.
set -euo pipefail

VERSION="1.1.0-feral"
APP_BASE="deluge-auto-reannounce"
INSTANCE=${DELUGE_INSTANCE:-default}
if [[ ! "$INSTANCE" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then echo "Invalid DELUGE_INSTANCE" >&2; exit 1; fi
if [ "$INSTANCE" = default ]; then APP="$APP_BASE"; BIN_NAME="deluge-reannounce"; else APP="${APP_BASE}-${INSTANCE}"; BIN_NAME="deluge-reannounce-${INSTANCE}"; fi
BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APP"
BIN_DIR="${HOME}/.local/bin"
BIN_FILE="$BIN_DIR/$BIN_NAME"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say(){ printf '[%s] %s\n' "$1" "$2"; }
die(){ say ERROR "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as the Feral slot user, not root."
command -v bash >/dev/null 2>&1 || die "bash is required"
PYTHON_BIN="${DELUGE_PYTHON:-}"

find_console() {
    if [ -n "${DELUGE_CONSOLE:-}" ] && [ -x "$DELUGE_CONSOLE" ]; then printf '%s\n' "$DELUGE_CONSOLE"; return; fi
    for candidate in "$HOME/bin/deluge-console" "$HOME/.local/bin/deluge-console" "$(command -v deluge-console 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return; }
    done
    return 1
}

CONSOLE=$(find_console) || die "deluge-console not found. Set DELUGE_CONSOLE=/full/path/to/deluge-console and rerun."

# Prefer the interpreter declared by deluge-console itself. Feral slots can
# have multiple Python installs, so PATH's generic python may be unrelated.
if [ -z "$PYTHON_BIN" ]; then
    SHEBANG=$(head -n 1 "$CONSOLE" 2>/dev/null || true)
    SHEBANG=${SHEBANG#\#!}
    SHEBANG=${SHEBANG#\!}
    read -r SHEBANG_BIN SHEBANG_ARG _ <<< "$SHEBANG"
    case "$(basename "$SHEBANG_BIN")" in
        env)
            if [ -n "$SHEBANG_ARG" ]; then PYTHON_BIN=$(command -v "$SHEBANG_ARG" 2>/dev/null || true); fi
            ;;
        python*) PYTHON_BIN="$SHEBANG_BIN" ;;
    esac
fi
if [ -z "$PYTHON_BIN" ]; then
    for candidate in "$HOME/bin/python2.7" "$HOME/.local/bin/python2.7" "$(command -v python2.7 2>/dev/null || true)" "$(command -v python 2>/dev/null || true)" "$(command -v python3 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then PYTHON_BIN="$candidate"; break; fi
    done
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    die "Python interpreter not found. Set DELUGE_PYTHON=/path/to/deluge-python."
fi
command -v install >/dev/null 2>&1 || die "install is required"

VERSION_TEXT=$("$CONSOLE" --version 2>&1 | head -n 1 || true)
case "$VERSION_TEXT" in *1.3.15*) ;; *) say WARNING "Expected Deluge 1.3.15; detected: ${VERSION_TEXT:-unknown}. Continuing, but compatibility is not guaranteed.";; esac

# Deluge 1.3 writes a concatenated header+config JSON document, so parse
# daemon_port as a scalar instead of passing the whole file to json.load().
DELUGE_CONFIG_DIR_RESOLVED="${DELUGE_CONFIG_DIR:-$HOME/.config/deluge}"
CORE_CONF="$DELUGE_CONFIG_DIR_RESOLVED/core.conf"
PORT=${DELUGE_PORT:-}
if [ -z "$PORT" ] && [ -r "$CORE_CONF" ]; then
    PORT=$(sed -n 's/^[[:space:]]*"daemon_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CORE_CONF" | head -n 1 || true)
fi
PORT=${PORT:-58846}
case "$PORT" in *[!0-9]*|'') die "Invalid Deluge daemon port";; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "Deluge daemon port out of range"
fi

[ -s "$SOURCE_DIR/scripts/reannounce-new.sh" ] || die "Missing scripts/reannounce-new.sh; run installer from repository checkout"
[ -s "$SOURCE_DIR/scripts/configure-execute.py" ] || die "Missing scripts/configure-execute.py"

mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"

# Preserve user timing preferences on upgrade.
config="$CONFIG_DIR/reannounce.conf"
if [ ! -e "$config" ]; then
cat > "$config" <<EOF2
DELUGE_CONSOLE="$CONSOLE"
DELUGE_CONFIG_DIR="$DELUGE_CONFIG_DIR_RESOLVED"
DELUGE_HOST="${DELUGE_HOST:-127.0.0.1}"
DELUGE_PORT="$PORT"
INITIAL_DELAY="${INITIAL_DELAY:-0.5}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"
MAX_RUNTIME="${MAX_RUNTIME:-900}"
REANNOUNCE_INTERVAL="${REANNOUNCE_INTERVAL:-15}"
SENT_TIMEOUT="${SENT_TIMEOUT:-20}"
CONSOLE_TIMEOUT="${CONSOLE_TIMEOUT:-20}"
LOG_FILE="$STATE_DIR/reannounce.log"
EOF2
else
    cp "$config" "$config.backup.$(date +%Y%m%d-%H%M%S)"
    # Keep existing config; add the console path only if not present.
    sed -i "s|^DELUGE_CONSOLE=.*|DELUGE_CONSOLE=\"$CONSOLE\"|" "$config"
    sed -i "s|^DELUGE_PORT=.*|DELUGE_PORT=\"$PORT\"|" "$config"
    if grep -q '^DELUGE_CONFIG_DIR=' "$config"; then sed -i "s|^DELUGE_CONFIG_DIR=.*|DELUGE_CONFIG_DIR=\"$DELUGE_CONFIG_DIR_RESOLVED\"|" "$config"; else printf '\nDELUGE_CONFIG_DIR="%s"\n' "$DELUGE_CONFIG_DIR_RESOLVED" >> "$config"; fi
    # Migrate only untouched project defaults; preserve any user-customized values.
    sed -i 's/^MAX_RUNTIME="300"$/MAX_RUNTIME="900"/' "$config"
    sed -i 's/^CHECK_INTERVAL="2"$/CHECK_INTERVAL="1"/' "$config"
    sed -i 's/^REANNOUNCE_INTERVAL="30"$/REANNOUNCE_INTERVAL="15"/' "$config"
    sed -i 's/^SENT_TIMEOUT="15"$/SENT_TIMEOUT="20"/' "$config"
    grep -q '^CONSOLE_TIMEOUT=' "$config" || printf '\nCONSOLE_TIMEOUT="20"\n' >> "$config"
fi
chmod 600 "$config"

install -m 755 "$SOURCE_DIR/scripts/reannounce-new.sh" "$BASE_DIR/reannounce-new.sh"

cat > "$BASE_DIR/execute-reannounce.sh" <<EOF2
#!/usr/bin/env bash
CONFIG_FILE="$config"
export CONFIG_FILE
set -a
. "$config"
set +a
exec "$BASE_DIR/reannounce-new.sh" "\$@"
EOF2
chmod 700 "$BASE_DIR/execute-reannounce.sh"

# Manual shortcut, limited to the single supplied torrent hash.
cat > "$BIN_FILE" <<EOF2
#!/usr/bin/env bash
set -a
. "$config"
set +a
exec "$BASE_DIR/execute-reannounce.sh" "\${1:?Usage: $BIN_NAME TORRENT_HASH}" "Manual Reannounce" "$HOME"
EOF2
chmod 700 "$BIN_FILE"

# Best-effort RPC registration with the same Python interpreter as Deluge.
# Never edit execute.conf behind the daemon or restart/toggle the plugin.
if "$PYTHON_BIN" -c 'import deluge.ui.client, twisted.internet' >/dev/null 2>&1; then
    if ! DELUGE_HOST="${DELUGE_HOST:-127.0.0.1}" DELUGE_CONFIG_DIR="$DELUGE_CONFIG_DIR_RESOLVED" "$PYTHON_BIN" "$SOURCE_DIR/scripts/configure-execute.py" "$PORT" "$BASE_DIR/execute-reannounce.sh"; then
        say WARNING "Automatic Execute RPC registration failed. Add Torrent Added event manually (see README)."
    fi
else
    say WARNING "Python cannot import Deluge/Twisted; skipping automatic Execute registration. Set DELUGE_PYTHON to Deluge's own Python and see README."
fi

echo
say OK "Feral rootless installation complete ($VERSION)"
printf 'Instance       : %s\nDeluge console : %s\nDaemon         : %s:%s\nInstall dir    : %s\nConfig         : %s\nLog            : %s/reannounce.log\nExecute wrapper: %s/execute-reannounce.sh\nManual command : %s\n' "$INSTANCE" "$CONSOLE" "${DELUGE_HOST:-127.0.0.1}" "$PORT" "$BASE_DIR" "$config" "$STATE_DIR" "$BASE_DIR" "$BIN_FILE"
printf '\nAdd this in Deluge WebUI: Preferences → Execute → Torrent Added → %s/execute-reannounce.sh\n' "$BASE_DIR"
printf 'Python used for detection/RPC: %s\n' "$PYTHON_BIN"
printf 'Ensure ~/.local/bin is in PATH for deluge-reannounce.\n'
