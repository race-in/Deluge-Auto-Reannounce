#!/usr/bin/env bash
# Deluge 1.3.15 Execute plugin: Torrent Added handler.
set -u

TORRENT_ID=${1:-}
TORRENT_NAME=${2:-Unknown Torrent}
DOWNLOAD_PATH=${3:-Unknown}

CONFIG_FILE=${CONFIG_FILE:-"${HOME:-}/.local/share/deluge-auto-reannounce/reannounce.conf"}
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

DELUGE_CONSOLE=${DELUGE_CONSOLE:-deluge-console}
DELUGE_HOST=${DELUGE_HOST:-127.0.0.1}
DELUGE_PORT=${DELUGE_PORT:-58846}
INITIAL_DELAY=${INITIAL_DELAY:-0.5}
CHECK_INTERVAL=${CHECK_INTERVAL:-2}
MAX_RUNTIME=${MAX_RUNTIME:-300}
REANNOUNCE_INTERVAL=${REANNOUNCE_INTERVAL:-30}
SENT_TIMEOUT=${SENT_TIMEOUT:-15}
LOG_FILE=${LOG_FILE:-"${HOME:-/tmp}/.local/state/deluge-auto-reannounce/reannounce.log"}

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}
fail() { log "ERROR | $*"; exit 1; }
now_seconds() {
    if [ -n "${NOW_COMMAND:-}" ]; then
        "$NOW_COMMAND"
    else
        date +%s
    fi
}

case "$TORRENT_ID" in
    *[!0-9a-fA-F]*|'') fail "Invalid or missing torrent hash" ;;
esac
[ "${#TORRENT_ID}" -eq 40 ] || fail "Torrent hash must be 40 hexadecimal characters"

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
for key in DELUGE_PORT MAX_RUNTIME REANNOUNCE_INTERVAL SENT_TIMEOUT; do
    eval "value=\${$key}"
    is_uint "$value" || fail "$key must be a non-negative integer"
done
for key in INITIAL_DELAY CHECK_INTERVAL; do
    eval "value=\${$key}"
    case "$value" in ''|*[!0-9.]*|.*.*) fail "$key must be a non-negative number";; esac
done
[ "$DELUGE_PORT" -ge 1 ] && [ "$DELUGE_PORT" -le 65535 ] || fail "DELUGE_PORT out of range"
[ "$MAX_RUNTIME" -gt 0 ] && [ "$CHECK_INTERVAL" != "0" ] || fail "MAX_RUNTIME and CHECK_INTERVAL must be positive"
command -v "$DELUGE_CONSOLE" >/dev/null 2>&1 || [ -x "$DELUGE_CONSOLE" ] || fail "deluge-console not found: $DELUGE_CONSOLE"

log "START | $TORRENT_NAME | $TORRENT_ID"
log "DOWNLOAD PATH | $DOWNLOAD_PATH"
sleep "$INITIAL_DELAY"
START_TIME=$(now_seconds)
LAST_REANNOUNCE=0
LAST_SENT_REANNOUNCE=0
ATTEMPT=0

while :; do
    now=$(now_seconds)
    elapsed=$((now - START_TIME))
    [ "$elapsed" -lt "$MAX_RUNTIME" ] || { log "TIMEOUT | ${elapsed}s | Attempts: $ATTEMPT | $TORRENT_NAME"; exit 1; }

    output=$("$DELUGE_CONSOLE" "connect ${DELUGE_HOST}:${DELUGE_PORT}; info -v ${TORRENT_ID}" 2>&1) || true
    status=$(printf '%s\n' "$output" | grep -i 'Tracker status:' || true)
    log "CHECK | ${elapsed}s | ${status:-Tracker status unavailable}"

    if printf '%s\n' "$status" | grep -qi 'Announce OK'; then
        log "SUCCESS | Announce OK after ${elapsed}s | Reannounce attempts: $ATTEMPT | $TORRENT_NAME"
        exit 0
    fi

    do_reannounce=0
    if printf '%s\n' "$status" | grep -qi 'Announce Sent'; then
        # Give an in-flight announce its response window; do not reset this timer on every poll.
        if [ "$LAST_SENT_REANNOUNCE" -eq 0 ]; then
            LAST_SENT_REANNOUNCE=$now
        elif [ $((now - LAST_SENT_REANNOUNCE)) -ge "$SENT_TIMEOUT" ]; then
            if [ "$LAST_REANNOUNCE" -eq 0 ] || [ $((now - LAST_REANNOUNCE)) -ge "$REANNOUNCE_INTERVAL" ]; then
                do_reannounce=1
                LAST_SENT_REANNOUNCE=$now
            fi
        fi
    else
        LAST_SENT_REANNOUNCE=0
        if [ "$LAST_REANNOUNCE" -eq 0 ] || [ $((now - LAST_REANNOUNCE)) -ge "$REANNOUNCE_INTERVAL" ]; then
            do_reannounce=1
        fi
    fi

    if [ "$do_reannounce" -eq 1 ]; then
        ATTEMPT=$((ATTEMPT + 1))
        LAST_REANNOUNCE=$now
        log "REANNOUNCE $ATTEMPT | ${elapsed}s | $TORRENT_NAME"
        "$DELUGE_CONSOLE" "connect ${DELUGE_HOST}:${DELUGE_PORT}; reannounce ${TORRENT_ID}" >/dev/null 2>&1 || log "WARNING | reannounce command returned failure"
    fi
    sleep "$CHECK_INTERVAL"
done
