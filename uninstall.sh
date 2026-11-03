#!/usr/bin/env bash
set -euo pipefail
INSTANCE=${DELUGE_INSTANCE:-default}
case "$INSTANCE" in
    default) APP="deluge-auto-reannounce"; BIN_NAME="deluge-reannounce" ;;
    *[!a-z0-9_-]*|"") echo "Invalid DELUGE_INSTANCE" >&2; exit 1 ;;
    *) APP="deluge-auto-reannounce-$INSTANCE"; BIN_NAME="deluge-reannounce-$INSTANCE" ;;
esac
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APP"
BIN_FILE="$HOME/.local/bin/$BIN_NAME"

if [ "$(id -u)" -eq 0 ]; then echo "Run as your Feral slot user, not root." >&2; exit 1; fi
printf 'This removes only Deluge Auto Reannounce instance "%s". Deluge settings and torrents are untouched.\n' "$INSTANCE"
printf 'Remove config and logs too? [y/N] '
read -r answer
rm -rf "$APP_DIR" "$BIN_FILE"
if [ "${answer:-N}" = y ] || [ "${answer:-N}" = Y ]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
fi
echo "Uninstall complete. Remove this instance's Torrent Added Execute entry in Deluge Preferences if it remains."
