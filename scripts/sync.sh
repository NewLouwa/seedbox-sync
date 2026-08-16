#!/bin/bash

CONFIG_SCRIPT="/opt/scripts/seedbox-sync/config.sh"

set -a
source /etc/seedbox-sync.env
set +a

if [ ! -f "$CONFIG_SCRIPT" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] config.sh not found at $CONFIG_SCRIPT - copy config.sh.example and adapt it" >&2
    exit 1
fi
source "$CONFIG_SCRIPT"

OLD_LOCK_THRESHOLD="$LOCK_TTL_SECONDS"

declare -A LVL_RANK=( [DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3 )
THRESHOLD="${LVL_RANK[$LOG_LEVEL]:-1}"

log() {
    local level="$1"; shift
    local msg="$*"
    local rank="${LVL_RANK[$level]:-1}"
    [ "$rank" -lt "$THRESHOLD" ] && return 0

    local ts line color reset
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[$ts] [$level] $msg"
    echo "$line" >> "$LOG_FILE"

    if [ -t 1 ]; then
        reset="\033[0m"
        case "$level" in
            DEBUG) color="\033[0;36m" ;;
            INFO)  color="\033[0;32m" ;;
            WARN)  color="\033[0;33m" ;;
            ERROR) color="\033[0;31m" ;;
        esac
        echo -e "${color}${line}${reset}"
    fi
}

FILTER="${1:-}"
RUN_SOURCE="${SOURCE:-cron}"

if [ -f "$PAUSE_FLAG" ] && [ "${FORCE_RUN:-0}" != "1" ]; then
    log INFO "Pause active - ${RUN_SOURCE} launch skipped (PID $$)"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR") ))
    if [ "$LOCK_AGE" -lt "$OLD_LOCK_THRESHOLD" ]; then
        log WARN "Lock detected (${LOCK_AGE}s < ${OLD_LOCK_THRESHOLD}s) - Exit"
        exit 1
    fi
    log WARN "Stale lock (${LOCK_AGE}s) - removing and restarting"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
trap '[ -n "${MONITOR_PID:-}" ] && kill "$MONITOR_PID" 2>/dev/null; rm -rf "$LOCK_DIR" "$PID_FILE"' EXIT
trap 'log WARN "Manually stopped (SIGTERM)"; exit 143' TERM
trap 'log WARN "Interrupted (SIGINT)"; exit 130' INT
echo $$ > "$PID_FILE"

log INFO "=============================================="
log INFO "Starting sync... (source: ${RUN_SOURCE}, PID $$)"

if ! declare -p MAPPINGS >/dev/null 2>&1; then
    log ERROR "MAPPINGS not defined - check the declare -A MAPPINGS block in $CONFIG_SCRIPT"
    exit 1
fi

ALL_KEYS=("${!MAPPINGS[@]}")

DELETE_FLAG=""
if [ "${DELETE_AFTER_IMPORT:-0}" = "1" ]; then
    DELETE_FLAG="--Remove-source-files"
    log WARN "DELETE_AFTER_IMPORT active - remote files will be deleted after a successful transfer (irreversible)"
fi

if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
    SSH_BASE=(ssh -n -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
elif command -v sshpass >/dev/null 2>&1; then
    SSH_BASE=(sshpass -p "$REMOTE_PASS" ssh -n -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
else
    SSH_BASE=()
fi

# Starts a background progress monitor (local vs remote size, every 60s)
# Returns the monitor's PID via the global MONITOR_PID variable (empty if unavailable)
start_progress_monitor() {
    local remote_dir="$1"
    local local_dir="$2"
    MONITOR_PID=""

    [ "${#SSH_BASE[@]}" -eq 0 ] && return 0

    local remote_size baseline
    remote_size=$("${SSH_BASE[@]}" "du -sb \"$remote_dir\" 2>/dev/null | cut -f1")
    echo "$remote_size" | grep -qE '^[0-9]+$' || return 0
    [ "$remote_size" -le 0 ] && return 0

    baseline=$(du -sb "$local_dir" 2>/dev/null | cut -f1)
    [ -z "$baseline" ] && baseline=0
    local start_ts
    start_ts=$(date +%s)

    (
        local cur elapsed transferred avg_kb pct remain eta_sec eta_min eta_txt tick=0
        local max_ticks=360   # Safety TTL ~6h (360 * 60s) - self-terminates even if orphaned
        while [ "$tick" -lt "$max_ticks" ]; do
            sleep 60
            tick=$((tick + 1))
            cur=$(du -sb "$local_dir" 2>/dev/null | cut -f1)
            [ -z "$cur" ] && cur=0
            elapsed=$(( $(date +%s) - start_ts ))
            transferred=$(( cur - baseline ))

            if [ "$cur" -ge "$remote_size" ]; then
                # Local >= remote: legacy files (old versions/re-releases never cleaned up
                # by mirror without --delete) skew the total, no reliable ETA
                log INFO "  Local >= total remote size (legacy files likely)"
                continue
            fi

            # Average throughput since the monitor started (not just the last minute) -
            # avoids sampling/rounding noise over too short an interval
            if [ "$elapsed" -gt 0 ] && [ "$transferred" -gt 0 ]; then
                avg_kb=$(( transferred / elapsed / 1024 ))
            else
                avg_kb=0
            fi

            pct=$(( cur * 100 / remote_size ))
            remain=$(( remote_size - cur ))
            if [ "$avg_kb" -gt 0 ]; then
                eta_sec=$(( remain / 1024 / avg_kb ))
                eta_min=$(( eta_sec / 60 ))
                eta_txt="${eta_min} min"
            else
                eta_txt="?"
            fi
            log INFO "  Progress ~${pct}% (avg: $(( avg_kb / 1024 )) MB/s, ETA ${eta_txt})"
        done
    ) &
    MONITOR_PID=$!
    echo "$MONITOR_PID" >> "$MONITOR_PID_FILE"
}

stop_progress_monitor() {
    if [ -n "${MONITOR_PID:-}" ]; then
        kill "$MONITOR_PID" 2>/dev/null
        grep -v "^${MONITOR_PID}$" "$MONITOR_PID_FILE" 2>/dev/null > "${MONITOR_PID_FILE}.tmp" || true
        mv -f "${MONITOR_PID_FILE}.tmp" "$MONITOR_PID_FILE" 2>/dev/null
    fi
    MONITOR_PID=""
}


CATEGORY_MATCH=0
if [ -n "$FILTER" ]; then
    for k in "${ALL_KEYS[@]}"; do
        echo "$k" | grep -qiF -- "$FILTER" && CATEGORY_MATCH=1
    done
fi

if [ -n "$FILTER" ] && [ "$CATEGORY_MATCH" -eq 0 ]; then
    # Specific title (movie/show), not a category - recursive search via SSH
    log INFO "Recursive search for title '$FILTER' via SSH..."
    TITLE_FOUND=0

    [ "${#SSH_BASE[@]}" -eq 0 ] && log WARN "No SSH_KEY or sshpass - title search unavailable, falling through to normal sync"

    if [ "${#SSH_BASE[@]}" -gt 0 ]; then
        # mindepth/maxdepth 2 = "title" level (media/Category/Title), not the files underneath
        RAW_MATCHES=$("${SSH_BASE[@]}" "find media -mindepth 2 -maxdepth 2 -iname '*${FILTER}*' 2>/dev/null")
        RAW_MATCH_COUNT=$(echo "$RAW_MATCHES" | grep -c . || true)
        log INFO "Remote search returned ${RAW_MATCH_COUNT} title-level match(es)"
        log DEBUG "Raw matches: $(echo "$RAW_MATCHES" | tr '\n' ' | ')"

        while IFS= read -r remote_full_path; do
            [ -z "$remote_full_path" ] && continue

            MATCHED_KEY=""
            for k in "${ALL_KEYS[@]}"; do
                case "$remote_full_path" in
                    "$k"/*) MATCHED_KEY="$k" ;;
                esac
                [ -n "$MATCHED_KEY" ] && break
            done
            if [ -z "$MATCHED_KEY" ]; then
                log WARN "Match '$remote_full_path' does not fall under any MAPPINGS key - skipped"
                continue
            fi

            local_folder="${MAPPINGS[$MATCHED_KEY]}"
            rel="${remote_full_path#"$MATCHED_KEY"/}"
            local_path="$LOCAL_BASE/$local_folder"

            TITLE_FOUND=1
            log INFO "Title match: ~/$remote_full_path"
            mkdir -p "$local_path/$rel"
            start_progress_monitor "$remote_full_path" "$local_path/$rel"
            TMP_OUT=$(mktemp)
            lftp -u "$REMOTE_USER,$REMOTE_PASS" sftp://$REMOTE_HOST << LFTPEOF 2>&1 | tee "$TMP_OUT" | while IFS= read -r line; do log INFO "  $line"; done
set ssl:verify-certificate no
set sftp:auto-confirm yes
set net:max-retries 3
set net:timeout 30
set xfer:use-temp-file yes
set xfer:temp-file-name ".*.lftp-tmp"
mirror --verbose --only-newer --continue $DELETE_FLAG "$remote_full_path" "$local_path/$rel"
bye
LFTPEOF
            RC_TITLE=${PIPESTATUS[0]}
            stop_progress_monitor
            TITLE_OUT=$(cat "$TMP_OUT")
            rm -f "$TMP_OUT"
            if [ "$RC_TITLE" -eq 0 ]; then
                log INFO "OK title '$rel'"
            else
                log ERROR "FAIL title '$rel': $(echo "$TITLE_OUT" | tail -n 5 | tr '\n' ' | ')"
            fi
        done <<< "$RAW_MATCHES"
    fi

    [ "$TITLE_FOUND" -eq 0 ] && log WARN "No title found for '$FILTER' - falling back to normal sync"
    log INFO "Title search complete, resuming full normal sync"
fi

if [ -n "$FILTER" ] && [ "$CATEGORY_MATCH" -eq 1 ]; then
    PRIORITY_KEYS=()
    OTHER_KEYS=()
    for k in "${ALL_KEYS[@]}"; do
        if echo "$k" | grep -qiF -- "$FILTER"; then
            PRIORITY_KEYS+=("$k")
        else
            OTHER_KEYS+=("$k")
        fi
    done
    if [ "${#PRIORITY_KEYS[@]}" -eq 0 ]; then
        log WARN "Filter '$FILTER' matches no folder - normal order"
    else
        log INFO "Filter '$FILTER' -> priority: ${PRIORITY_KEYS[*]}"
    fi
    ORDERED_KEYS=("${PRIORITY_KEYS[@]}" "${OTHER_KEYS[@]}")
else
    ORDERED_KEYS=("${ALL_KEYS[@]}")
fi

SUCCESS=0
FAIL=0
FAILED_PATHS=()

for remote_path in "${ORDERED_KEYS[@]}"; do
    local_folder="${MAPPINGS[$remote_path]}"
    local_path="$LOCAL_BASE/$local_folder"
    mkdir -p "$local_path"

    log INFO "Starting: ~/$remote_path -> $local_path"
    START_TS=$(date +%s)

    start_progress_monitor "$remote_path" "$local_path"
    TMP_OUT=$(mktemp)
    lftp -u "$REMOTE_USER,$REMOTE_PASS" sftp://$REMOTE_HOST << LFTPEOF 2>&1 | tee "$TMP_OUT" | while IFS= read -r line; do log INFO "  $line"; done
set ssl:verify-certificate no
set sftp:auto-confirm yes
set net:max-retries 3
set net:timeout 30
set xfer:use-temp-file yes
set xfer:temp-file-name ".*.lftp-tmp"
mirror --verbose --only-newer --continue $DELETE_FLAG "$remote_path" "$local_path"
bye
LFTPEOF
    RC=${PIPESTATUS[0]}
    stop_progress_monitor
    LFTP_OUT=$(cat "$TMP_OUT")
    rm -f "$TMP_OUT"
    DURATION=$(( $(date +%s) - START_TS ))

    if [ "$RC" -eq 0 ]; then
        ((SUCCESS++))
        log INFO "OK  ~/$remote_path (${DURATION}s)"
    else
        ((FAIL++))
        FAILED_PATHS+=("$remote_path")
        log ERROR "FAIL ~/$remote_path (${DURATION}s) rc=$RC"
        log ERROR "lftp: $(echo "$LFTP_OUT" | tail -n 5 | tr '\n' ' | ')"
    fi
done

log INFO "=============================================="
if [ "$FAIL" -eq 0 ]; then
    log INFO "DONE: $SUCCESS succeeded, $FAIL failed"
else
    log WARN "DONE: $SUCCESS succeeded, $FAIL failed -> ${FAILED_PATHS[*]}"
fi
