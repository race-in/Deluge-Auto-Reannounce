#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/deluge-auto-reannounce"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/deluge-auto-reannounce"
BIN_FILE="$HOME/.local/bin/deluge-reannounce"

if [ "$(id -u)" -eq 0 ]; then echo "Run as your Feral slot user, not root." >&2; exit 1; fi
printf 'This removes only Deluge Auto Reannounce files. Deluge settings and torrents are untouched.\n'
printf 'Remove config and logs too? [y/N] '
read -r answer
rm -rf "$APP_DIR" "$BIN_FILE"
if [ "${answer:-N}" = y ] || [ "${answer:-N}" = Y ]; then
    rm -rf "$CONFIG_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}/deluge-auto-reannounce"
fi
echo "Uninstall complete. Remove the Torrent Added Execute entry in Deluge Preferences if it remains."
