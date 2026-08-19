#!/bin/bash

CONFIG_SCRIPT="/opt/scripts/seedbox-sync/config.sh"

if [ ! -f "$CONFIG_SCRIPT" ]; then
    echo "config.sh not found at $CONFIG_SCRIPT - copy config.sh.example and adapt it" >&2
    exit 1
fi
source "$CONFIG_SCRIPT"

if [ -t 1 ]; then
    C_OK="\033[0;32m"
    C_ERR="\033[0;31m"
    C_WARN="\033[0;33m"
    C_INFO="\033[0;36m"
    C_RESET="\033[0m"
else
    C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_RESET=""
fi

ok()   { echo -e "${C_OK}$*${C_RESET}"; }
err()  { echo -e "${C_ERR}$*${C_RESET}"; }
warn() { echo -e "${C_WARN}$*${C_RESET}"; }
info() { echo -e "${C_INFO}$*${C_RESET}"; }

case "$1" in
    install-logrotate)
        if [ "$(id -u)" -ne 0 ]; then
            err "Must run as root (writes to /etc/logrotate.d/)"
            exit 1
        fi
        cat > /etc/logrotate.d/ass-sync << EOF
$LOG_FILE {
    $LOG_ROTATE_FREQUENCY
    rotate $LOG_ROTATE_COUNT
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        ok "Generated /etc/logrotate.d/ass-sync for $LOG_FILE ($LOG_ROTATE_FREQUENCY, keep $LOG_ROTATE_COUNT)"
        ;;
    watch)
        if [ ! -f "$LOG_FILE" ]; then
            err "Log file not found: $LOG_FILE"
            exit 1
        fi
        info "Following $LOG_FILE live (Ctrl+C to quit)..."
        tail -n 50 -f "$LOG_FILE" | while IFS= read -r line; do
            case "$line" in
                *"[ERROR]"*) err "$line" ;;
                *"[WARN]"*)  warn "$line" ;;
                *"[DEBUG]"*) info "$line" ;;
                *"[INFO]"*)  ok "$line" ;;
                *)           echo "$line" ;;
            esac
        done
        ;;
    pause)
        touch "$PAUSE_FLAG"
        warn "Sync PAUSED (blocks next launches, does not stop a running sync)"
        ;;
    resume)
        rm -f "$PAUSE_FLAG"
        ok "Sync RESUMED"
        ;;
    test)
        set -a
        source /etc/seedbox-sync.env
        set +a
        info "Testing connection to $REMOTE_HOST..."
        # Credentials go through stdin (user command), never on the argv/-e line,
        # so they don't leak into ps/pgrep. Host stays on argv (not a secret).
        OUT=$(lftp "sftp://$REMOTE_HOST" << LFTPEOF 2>&1
user "$REMOTE_USER" "$REMOTE_PASS"
set ssl:verify-certificate no
set net:max-retries 1
set net:timeout 15
ls
bye
LFTPEOF
)
        RC=$?
        if [ "$RC" -eq 0 ]; then
            ok "OK - connection and auth valid"
        else
            err "FAILED (rc=$RC)"
            echo "$OUT" | tail -n 10
        fi
        ;;
    find)
        NAME="${2:-}"
        if [ -z "$NAME" ]; then
            echo "Usage: $0 find <name>"
            exit 1
        fi
        set -a
        source /etc/seedbox-sync.env
        set +a

        if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
            SSH_BASE=(ssh -n -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
        elif command -v sshpass >/dev/null 2>&1; then
            SSH_BASE=(sshpass -p "$REMOTE_PASS" ssh -n -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
        else
            err "No SSH_KEY in /etc/seedbox-sync.env and sshpass not installed - search unavailable"
            echo "Configure an SSH key (recommended) or: apt install -y sshpass"
            exit 1
        fi

        info "Recursive search for '$NAME' via SSH..."
        RESULTS=$("${SSH_BASE[@]}" "find media -iname '*${NAME}*' 2>/dev/null")
        RC=$?
        if [ "$RC" -ne 0 ]; then
            err "SSH connection failed (rc=$RC)"
            exit 1
        fi
        if [ -z "$RESULTS" ]; then
            warn "No results"
        else
            echo "$RESULTS" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                ok "  $line"
            done
        fi
        ;;
    start)
        FILTER="${2:-}"
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            err "Already running (PID $PID) - use 'stop' first or wait for it to finish"
            exit 1
        fi
        info "Manual launch${FILTER:+ (priority: $FILTER)}..."
        nohup env FORCE_RUN=1 SOURCE=manual /opt/scripts/seedbox-sync/scripts/sync.sh "$FILTER" >> /var/log/cron-sync.log 2>&1 &
        disown
        ok "Launched in background, PID $!"
        echo "Follow: tail -f /var/log/ass-sync.log"
        ;;
    stop)
        # Graceful shutdown - see docs: a hard SIGKILL on lftp mid-transfer used to
        # leave the local file in a wrong-size state, forcing a full re-download on
        # the next run ("Removing old file" + "Transferring file"). Now we SIGTERM
        # lftp so it exits cleanly, leaving its ".*.lftp-tmp" partial in a valid,
        # resumable state (mirror --continue picks it up). SIGKILL is a last resort.
        PID=$(cat "$PID_FILE" 2>/dev/null || true)

        # 1. Signal sync.sh first (its TERM trap is deferred until the lftp pipeline
        #    ends, so it won't move on to the next category once lftp is gone).
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            warn "Stopping sync.sh (PID $PID)..."
            kill -TERM "$PID" 2>/dev/null
        else
            info "No sync.sh running (PID file missing or stale)"
        fi

        # 2. Gracefully stop lftp so the partial file is flushed and resumable.
        if pkill -TERM -f "lftp.*sftp://" 2>/dev/null; then
            warn "Sent SIGTERM to lftp - waiting for it to flush the partial file..."
            for _ in $(seq 1 15); do
                pgrep -f "lftp.*sftp://" >/dev/null 2>&1 || break
                sleep 1
            done
            if pgrep -f "lftp.*sftp://" >/dev/null 2>&1; then
                err "lftp still alive after 15s - forcing SIGKILL (partial may need re-download)"
                pkill -9 -f "lftp.*sftp://" 2>/dev/null
            else
                ok "lftp exited cleanly - partial left in resumable state"
            fi
        fi

        # 3. Now that the pipeline is closed, give sync.sh's TERM trap a moment,
        #    then SIGKILL as a last resort.
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            for _ in $(seq 1 5); do
                kill -0 "$PID" 2>/dev/null || break
                sleep 1
            done
            kill -0 "$PID" 2>/dev/null && { err "sync.sh still alive - SIGKILL"; kill -9 "$PID" 2>/dev/null; }
        fi

        # 4. Reap orphaned progress monitors.
        if [ -f "$MONITOR_PID_FILE" ]; then
            while IFS= read -r mpid; do
                [ -z "$mpid" ] && continue
                if kill -0 "$mpid" 2>/dev/null; then
                    kill -9 "$mpid" 2>/dev/null
                    warn "Orphaned progress monitor killed (PID $mpid)"
                fi
            done < "$MONITOR_PID_FILE"
        fi
        rm -rf "$LOCK_DIR" "$PID_FILE" "$MONITOR_PID_FILE"
        ok "Lock and PID cleaned up"
        ;;
    status)
        if [ -f "$PAUSE_FLAG" ]; then
            warn "Sync PAUSED (no new launches)"
        else
            ok "Sync ACTIVE (no pause applied)"
        fi
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            info "Run in progress: PID $PID"
        else
            echo "No run in progress"
        fi
        ;;
    db)
        shift
        # Local audit ledger (SQLite) of remote vs local state. Read-only:
        # it never downloads/deletes/moves - see scripts/seedbox-db.py.
        if ! command -v python3 >/dev/null 2>&1; then
            err "python3 not found - required for 'sbs db'"
            exit 1
        fi
        set -a
        source /etc/seedbox-sync.env
        set +a
        # Serialize the MAPPINGS assoc-array as "remote_key<TAB>local_folder" lines
        # so the Python tool reuses config.sh as the single source of truth.
        MAP_STR=""
        for k in "${!MAPPINGS[@]}"; do
            MAP_STR+="${k}"$'\t'"${MAPPINGS[$k]}"$'\n'
        done
        SEEDBOX_MAPPINGS="$MAP_STR" \
        SEEDBOX_DB="${SEEDBOX_DB:-/opt/scripts/seedbox-sync/state/seedbox.db}" \
        LOCAL_BASE="$LOCAL_BASE" \
            python3 /opt/scripts/seedbox-sync/scripts/seedbox-db.py "$@"
        ;;
    help|--help|-h|"")
        cat <<EOF

$(info "sbs") - seedbox sync control

$(ok "SYNC")
  start [filter]    launch a sync now (optional priority: a category or a title)
  stop              stop the running sync gracefully (partials stay resumable)
  pause             block the next cron launches (does not stop a running sync)
  resume            remove the pause

$(ok "MONITOR")
  status            paused? run in progress?
  watch             follow the log live, colorized
  test              check the seedbox connection and auth

$(ok "REMOTE")
  find <name>       recursive search for a title on the seedbox (via SSH)

$(ok "DATABASE")  local audit ledger, read-only (never downloads/deletes)
  db resync         refresh both sides (scan-remote + scan-local)
  db scan-remote    snapshot the seedbox (sizes/mtimes)
  db scan-local     snapshot /mnt/dl (+ partial hashes)
  db diff           missing / incomplete / mismatch / extra / ok
  db status         counters + size left to fetch
  db fetch [pat] [--dry-run] [--limit N]   download only missing/incomplete
  db verify [pat] [--full]   re-hash local files, flag corruption

$(ok "SETUP")
  install-logrotate generate /etc/logrotate.d/ass-sync

EOF
        exit 0
        ;;
    *)
        err "Unknown command: '$1'"
        echo "Run '$0 help' to see available commands." >&2
        exit 1
        ;;
esac
