#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/.config/deluge" "$HOME_DIR/.config/deluge-jerry" "$MOCK_BIN"
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    if HOME="$HOME_DIR" bash "$ROOT/install.sh" >/dev/null 2>&1; then
        echo 'installer unexpectedly accepted root'; exit 1
    fi
fi
cat > "$MOCK_BIN/id" <<'MOCK_ID'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then echo 1000; else exec /usr/bin/id "$@"; fi
MOCK_ID
chmod +x "$MOCK_BIN/id"
cat > "$HOME_DIR/bin/deluge-console" <<'MOCK_CONSOLE'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'deluge-console 1.3.15'; exit 0; fi
echo 'mock console: no daemon needed for installer smoke test'
MOCK_CONSOLE
chmod +x "$HOME_DIR/bin/deluge-console"
cat > "$HOME_DIR/.config/deluge/core.conf" <<'CORE'
{
  "file": 1, "format": 1
}{
  "daemon_port": 31851
}
CORE
HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_STATE_HOME="$HOME_DIR/.local/state" PATH="$MOCK_BIN:$PATH" DELUGE_CONSOLE="$HOME_DIR/bin/deluge-console" \
  DELUGE_PYTHON="$(command -v python3)" bash "$ROOT/install.sh" > "$TMP/install.log" 2>&1
APP="$HOME_DIR/.local/share/deluge-auto-reannounce"
CFG="$HOME_DIR/.config/deluge-auto-reannounce/reannounce.conf"
[ -x "$APP/reannounce-new.sh" ]
[ -x "$APP/execute-reannounce.sh" ]
[ -x "$HOME_DIR/.local/bin/deluge-reannounce" ]
[ -f "$CFG" ]
grep -q '^DELUGE_PORT="31851"$' "$CFG"
grep -q '^CHECK_INTERVAL="1"$' "$CFG"
grep -q '^MAX_RUNTIME="900"$' "$CFG"
grep -q '^REANNOUNCE_INTERVAL="15"$' "$CFG"
grep -q '^SENT_TIMEOUT="20"$' "$CFG"
grep -q 'Torrent Added' "$TMP/install.log"
[ ! -e "$HOME_DIR/.config/deluge/execute.conf" ]
grep -Fq -- "execute-reannounce.sh" "$HOME_DIR/.local/bin/deluge-reannounce"
[ "$(stat -c '%a' "$CFG")" = 600 ]
# Simulate an older default config and verify only untouched defaults migrate.
sed -i 's/^CHECK_INTERVAL="1"$/CHECK_INTERVAL="7"/' "$CFG"
sed -i 's/^MAX_RUNTIME="900"$/MAX_RUNTIME="300"/' "$CFG"
sed -i 's/^REANNOUNCE_INTERVAL="15"$/REANNOUNCE_INTERVAL="30"/' "$CFG"
sed -i 's/^SENT_TIMEOUT="20"$/SENT_TIMEOUT="15"/' "$CFG"
HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_STATE_HOME="$HOME_DIR/.local/state" PATH="$MOCK_BIN:$PATH" DELUGE_CONSOLE="$HOME_DIR/bin/deluge-console" DELUGE_PYTHON="$(command -v python3)" bash "$ROOT/install.sh" > "$TMP/upgrade.log" 2>&1
grep -q '^CHECK_INTERVAL="7"$' "$CFG"
grep -q '^MAX_RUNTIME="900"$' "$CFG"
grep -q '^REANNOUNCE_INTERVAL="15"$' "$CFG"
grep -q '^SENT_TIMEOUT="20"$' "$CFG"
[ -f "$(find "$(dirname "$CFG")" -name 'reannounce.conf.backup.*' -print -quit)" ]

cat > "$HOME_DIR/.config/deluge-jerry/core.conf" <<'CORE'
{
  "file": 1, "format": 1
}{
  "daemon_port": 28602
}
CORE
HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_STATE_HOME="$HOME_DIR/.local/state" PATH="$MOCK_BIN:$PATH" DELUGE_CONSOLE="$HOME_DIR/bin/deluge-console" DELUGE_PYTHON="$(command -v python3)" DELUGE_INSTANCE=jerry DELUGE_CONFIG_DIR="$HOME_DIR/.config/deluge-jerry" bash "$ROOT/install.sh" > "$TMP/jerry-install.log" 2>&1
JERRY_APP="$HOME_DIR/.local/share/deluge-auto-reannounce-jerry"
JERRY_CFG="$HOME_DIR/.config/deluge-auto-reannounce-jerry/reannounce.conf"
[ -x "$JERRY_APP/reannounce-new.sh" ]
[ -x "$JERRY_APP/execute-reannounce.sh" ]
[ -x "$HOME_DIR/.local/bin/deluge-reannounce-jerry" ]
grep -q '^DELUGE_PORT="28602"$' "$JERRY_CFG"
grep -Fq -- "DELUGE_CONFIG_DIR=\"$HOME_DIR/.config/deluge-jerry\"" "$JERRY_CFG"
grep -Fq -- "execute-reannounce.sh" "$HOME_DIR/.local/bin/deluge-reannounce-jerry"
grep -q 'deluge-auto-reannounce-jerry/execute-reannounce.sh' "$TMP/jerry-install.log"
grep -q '^DELUGE_PORT="31851"$' "$CFG"
[ -x "$HOME_DIR/.local/bin/deluge-reannounce" ]
if HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_STATE_HOME="$HOME_DIR/.local/state" PATH="$MOCK_BIN:$PATH" DELUGE_CONSOLE="$HOME_DIR/bin/deluge-console" DELUGE_PYTHON="$(command -v python3)" DELUGE_INSTANCE="../bad" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    echo "installer unexpectedly accepted invalid instance name"; exit 1
fi
if HOME="$HOME_DIR" PATH="$MOCK_BIN:$PATH" DELUGE_INSTANCE="--bad" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    echo "installer unexpectedly accepted a leading dash in instance name"; exit 1
fi

echo 'rootless multi-instance installer mock test passed'
