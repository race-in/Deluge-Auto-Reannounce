#!/usr/bin/env bash
# Deluge 1.3.15 Execute plugin: Torrent Added handler.
# Uses torrent-specific Pause -> Resume to trigger a fresh tracker announce.
set -u
umask 077

TORRENT_ID=${1:-}
TORRENT_NAME=${2:-Unknown Torrent}
DOWNLOAD_PATH=${3:-Unknown}

CONFIG_FILE=${CONFIG_FILE:-"${XDG_CONFIG_HOME:-${HOME:-}/.config}/deluge-auto-reannounce/reannounce.conf"}
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

DELUGE_CONSOLE=${DELUGE_CONSOLE:-deluge-console}
DELUGE_CONFIG_DIR=${DELUGE_CONFIG_DIR:-"${HOME:-}/.config/deluge"}
DELUGE_HOST=${DELUGE_HOST:-127.0.0.1}
DELUGE_PORT=${DELUGE_PORT:-58846}
INITIAL_DELAY=${INITIAL_DELAY:-0.5}
CHECK_INTERVAL=${CHECK_INTERVAL:-2}
MAX_RUNTIME=${MAX_RUNTIME:-300}
REANNOUNCE_INTERVAL=${REANNOUNCE_INTERVAL:-30}
SENT_TIMEOUT=${SENT_TIMEOUT:-15}
CONSOLE_TIMEOUT=${CONSOLE_TIMEOUT:-20}
LOG_FILE=${LOG_FILE:-"${HOME:-/tmp}/.local/state/deluge-auto-reannounce/reannounce.log"}
LOCK_ROOT=${LOCK_ROOT:-"${LOG_FILE%/*}/locks"}

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}
fail() { log "ERROR | $*"; exit 1; }
now_seconds() {
    if [ -n "${NOW_COMMAND:-}" ]; then "$NOW_COMMAND"; else date +%s; fi
}
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_decimal() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

case "$TORRENT_ID" in
    *[!0-9a-fA-F]*|'') fail "Invalid or missing torrent hash" ;;
esac
[ "${#TORRENT_ID}" -eq 40 ] || fail "Torrent hash must be 40 hexadecimal characters"

for key in DELUGE_PORT MAX_RUNTIME REANNOUNCE_INTERVAL SENT_TIMEOUT CONSOLE_TIMEOUT; do
    case "$key" in
        DELUGE_PORT) value=$DELUGE_PORT ;;
        MAX_RUNTIME) value=$MAX_RUNTIME ;;
        REANNOUNCE_INTERVAL) value=$REANNOUNCE_INTERVAL ;;
        SENT_TIMEOUT) value=$SENT_TIMEOUT ;;
        CONSOLE_TIMEOUT) value=$CONSOLE_TIMEOUT ;;
    esac
    is_uint "$value" || fail "$key must be a non-negative integer"
done
for key in INITIAL_DELAY CHECK_INTERVAL; do
    case "$key" in
        INITIAL_DELAY) value=$INITIAL_DELAY ;;
        CHECK_INTERVAL) value=$CHECK_INTERVAL ;;
    esac
    is_decimal "$value" || fail "$key must be a non-negative decimal number"
done
[ "$DELUGE_PORT" -ge 1 ] && [ "$DELUGE_PORT" -le 65535 ] || fail "DELUGE_PORT out of range"
[ "$CONSOLE_TIMEOUT" -ge 1 ] || fail "CONSOLE_TIMEOUT must be at least 1 second"
awk -v n="$CHECK_INTERVAL" 'BEGIN { exit !(n > 0) }' || fail "CHECK_INTERVAL must be positive"
command -v "$DELUGE_CONSOLE" >/dev/null 2>&1 || [ -x "$DELUGE_CONSOLE" ] || fail "deluge-console not found: $DELUGE_CONSOLE"

# One runner per torrent per Deluge instance. mkdir is atomic and needs no flock.
mkdir -p "$LOCK_ROOT" 2>/dev/null || fail "Cannot create lock directory: $LOCK_ROOT"
LOCK_PATH="$LOCK_ROOT/$TORRENT_ID.lock"
if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    LOCK_PID=""
    [ ! -r "$LOCK_PATH/pid" ] || read -r LOCK_PID < "$LOCK_PATH/pid"
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "DUPLICATE | Runner already active (pid $LOCK_PID) | $TORRENT_NAME"
        exit 0
    fi
    # A lock with no PID may be in the tiny window between mkdir and pid write.
    [ -n "$LOCK_PID" ] || { log "LOCK_BUSY | Lock is being initialized | $TORRENT_NAME"; exit 0; }
    rm -rf "$LOCK_PATH" 2>/dev/null || fail "Cannot clear stale lock: $LOCK_PATH"
    mkdir "$LOCK_PATH" 2>/dev/null || { log "LOCK_BUSY | Another runner acquired lock | $TORRENT_NAME"; exit 0; }
fi
printf '%s\n' "$$" > "$LOCK_PATH/pid"
cleanup() { rm -rf "$LOCK_PATH" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

run_console() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "${CONSOLE_TIMEOUT}s" "$DELUGE_CONSOLE" -c "$DELUGE_CONFIG_DIR" "connect ${DELUGE_HOST}:${DELUGE_PORT}; $1" 2>&1
    else
        "$DELUGE_CONSOLE" -c "$DELUGE_CONFIG_DIR" "connect ${DELUGE_HOST}:${DELUGE_PORT}; $1" 2>&1
    fi
}
get_info() {
    INFO_OUTPUT=$(run_console "info -v ${TORRENT_ID}")
    INFO_RC=$?
    INFO_STATUS=$(printf '%s\n' "$INFO_OUTPUT" | grep -i 'Tracker status:' || true)
    INFO_STATE=$(printf '%s\n' "$INFO_OUTPUT" | sed -n 's/^[[:space:]]*State:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
}
is_success() {
    printf '%s\n' "$INFO_STATUS" | grep -qiE 'Tracker status:.*Announce OK([[:space:]]|$)'
}

log "START | $TORRENT_NAME | $TORRENT_ID"
log "DOWNLOAD PATH | $DOWNLOAD_PATH"
sleep "$INITIAL_DELAY"
START_TIME=$(now_seconds)
LAST_REANNOUNCE=0
LAST_SENT_REANNOUNCE=0
ATTEMPT=0
NEED_RESUME=0
TIMEOUT_LOGGED=0

while :; do
    now=$(now_seconds)
    elapsed=$((now - START_TIME))

    # Recovery takes priority over the announce timeout: never abandon a torrent
    # after a pause attempt until Deluge confirms it is no longer paused.
    if [ "$NEED_RESUME" -eq 1 ]; then
        resume_output=$(run_console "resume ${TORRENT_ID}")
        resume_rc=$?
        if [ "$resume_rc" -eq 0 ]; then
            get_info
            if [ "$INFO_RC" -eq 0 ] && [ -n "$INFO_STATE" ] && [ "$INFO_STATE" != "Paused" ]; then
                NEED_RESUME=0
                LAST_REANNOUNCE=$(now_seconds)
                LAST_SENT_REANNOUNCE=0
                log "RESUME_RECOVERED | State: $INFO_STATE | $TORRENT_NAME"
            else
                log "RESUME_VERIFY_PENDING | rc=$INFO_RC state=${INFO_STATE:-unknown} | $resume_output | $TORRENT_NAME"
            fi
        else
            log "RESUME_RETRY_FAILED | $resume_output | $TORRENT_NAME"
        fi
        if [ "$NEED_RESUME" -eq 1 ]; then
            if [ "$MAX_RUNTIME" -gt 0 ] && [ "$elapsed" -ge "$MAX_RUNTIME" ] && [ "$TIMEOUT_LOGGED" -eq 0 ]; then
                log "TIMEOUT_PENDING_RESUME | ${elapsed}s | Continuing recovery until torrent is resumed | $TORRENT_NAME"
                TIMEOUT_LOGGED=1
            fi
            sleep "$CHECK_INTERVAL"
            continue
        fi
    fi

    get_info
    if [ "$INFO_RC" -ne 0 ] || [ -z "$INFO_STATUS" ] || [ -z "$INFO_STATE" ]; then
        log "RPC_UNAVAILABLE | rc=$INFO_RC state=${INFO_STATE:-unknown} | ${INFO_OUTPUT:-no output}"
        if [ "$MAX_RUNTIME" -gt 0 ] && [ "$elapsed" -ge "$MAX_RUNTIME" ]; then
            log "TIMEOUT | ${elapsed}s | RPC/status unavailable; no torrent action taken | $TORRENT_NAME"
            exit 2
        fi
        sleep "$CHECK_INTERVAL"
        continue
    fi

    log "CHECK | ${elapsed}s | State: $INFO_STATE | $INFO_STATUS"
    if is_success; then
        log "SUCCESS | Announce OK after ${elapsed}s | Reannounce attempts: $ATTEMPT | $TORRENT_NAME"
        exit 0
    fi

    if [ "$MAX_RUNTIME" -gt 0 ] && [ "$elapsed" -ge "$MAX_RUNTIME" ]; then
        log "TIMEOUT | ${elapsed}s | Attempts: $ATTEMPT | $TORRENT_NAME"
        exit 2
    fi

    # Respect the user's original paused state and avoid disrupting queued,
    # checking, allocating, moving, or errored torrents.
    if [ "$INFO_STATE" = "Paused" ]; then
        log "SKIPPED | Torrent was already paused; preserving user state | $TORRENT_NAME"
        exit 0
    fi
    case "$INFO_STATE" in
        Downloading|Seeding) ;;
        *)
            log "DEFER | State $INFO_STATE is not active; waiting without changing torrent state | $TORRENT_NAME"
            sleep "$CHECK_INTERVAL"
            continue
            ;;
    esac

    do_reannounce=0
    if printf '%s\n' "$INFO_STATUS" | grep -qi 'Announce Sent'; then
        if [ "$LAST_SENT_REANNOUNCE" -eq 0 ]; then
            LAST_SENT_REANNOUNCE=$now
        elif [ $((now - LAST_SENT_REANNOUNCE)) -ge "$SENT_TIMEOUT" ] && \
             { [ "$LAST_REANNOUNCE" -eq 0 ] || [ $((now - LAST_REANNOUNCE)) -ge "$REANNOUNCE_INTERVAL" ]; }; then
            do_reannounce=1
            LAST_SENT_REANNOUNCE=$now
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
        log "PAUSE_RESUME $ATTEMPT | ${elapsed}s | $TORRENT_NAME"
        pause_output=$(run_console "pause ${TORRENT_ID}")
        pause_rc=$?
        # Verify the daemon actually paused this exact torrent. Regardless of
        # the result, always issue resume: the pause may have reached Deluge
        # even when the console returned an error or timed out.
        sleep 1
        get_info
        pause_confirmed=0
        PAUSE_STATE=${INFO_STATE:-unknown}
        if [ "$INFO_RC" -eq 0 ] && [ "$INFO_STATE" = "Paused" ]; then
            pause_confirmed=1
        fi
        resume_output=$(run_console "resume ${TORRENT_ID}")
        resume_rc=$?
        if [ "$resume_rc" -eq 0 ]; then
            get_info
            if [ "$INFO_RC" -eq 0 ] && [ -n "$INFO_STATE" ] && [ "$INFO_STATE" != "Paused" ]; then
                LAST_REANNOUNCE=$(now_seconds)
                LAST_SENT_REANNOUNCE=0
                if [ "$pause_confirmed" -eq 1 ]; then
                    log "PAUSE_RESUME_OK | State: $INFO_STATE | $TORRENT_NAME"
                else
                    log "PAUSE_NOT_CONFIRMED_BUT_RESUMED | pause_rc=$pause_rc pause_state=$PAUSE_STATE pause=$pause_output | State: $INFO_STATE | $TORRENT_NAME"
                fi
            else
                NEED_RESUME=1
                log "RESUME_VERIFY_PENDING | pause_rc=$pause_rc resume_rc=$resume_rc state=${INFO_STATE:-unknown} | $TORRENT_NAME"
            fi
        else
            NEED_RESUME=1
            log "RESUME_FAILED | $resume_output | will retry resume | $TORRENT_NAME"
        fi
        if [ "$pause_rc" -ne 0 ] && [ "$resume_rc" -ne 0 ]; then
            log "PAUSE_AND_RESUME_FAILED | pause=$pause_output resume=$resume_output | $TORRENT_NAME"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
