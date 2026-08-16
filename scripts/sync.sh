#!/bin/bash

set -a
source /etc/seedbox-sync.env
set +a

LOCAL_BASE="${LOCAL_BASE:-/mnt/dl}"
PAUSE_FLAG="/opt/scripts/seedbox-sync/PAUSED"
LOCK_DIR="/tmp/ass.lock.d"
PID_FILE="/tmp/ass-sync.pid"
LOG_FILE="/var/log/ass-sync.log"
OLD_LOCK_THRESHOLD=3600
LOG_LEVEL="${LOG_LEVEL:-INFO}"   # DEBUG < INFO < WARN < ERROR

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

if [ -f "$PAUSE_FLAG" ] && [ "${FORCE_RUN:-0}" != "1" ]; then
    log INFO "Pause active - Exit"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR") ))
    if [ "$LOCK_AGE" -lt "$OLD_LOCK_THRESHOLD" ]; then
        log WARN "Lock detecte (${LOCK_AGE}s < ${OLD_LOCK_THRESHOLD}s) - Exit"
        exit 1
    fi
    log WARN "Lock ancien (${LOCK_AGE}s) - Suppression et restart"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
trap 'rm -rf "$LOCK_DIR" "$PID_FILE"' EXIT
trap 'log WARN "Arrete manuellement (SIGTERM)"; exit 143' TERM
trap 'log WARN "Interrompu (SIGINT)"; exit 130' INT
echo $$ > "$PID_FILE"

log INFO "=============================================="
log INFO "Demarrage sync..."

declare -A MAPPINGS=(
    ['media/Anime']='anime'
    ['media/Animated Movies']='Animated Movies'
    ['media/Books']='books'
    ['media/Cartoons']='cartoons'
    ['media/Movies']='movies'
    ['media/TV Shows']='shows'
    ['media/adult-media']='adult-media'
    ['media/Music']='music'
)

ALL_KEYS=("${!MAPPINGS[@]}")

CATEGORY_MATCH=0
if [ -n "$FILTER" ]; then
    for k in "${ALL_KEYS[@]}"; do
        echo "$k" | grep -qiF -- "$FILTER" && CATEGORY_MATCH=1
    done
fi

if [ -n "$FILTER" ] && [ "$CATEGORY_MATCH" -eq 0 ]; then
    # Titre precis (film/serie), pas une categorie - recherche recursive via SSH
    log INFO "Recherche recursive du titre '$FILTER' via SSH..."
    TITLE_FOUND=0

    if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
        SSH_BASE=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
    elif command -v sshpass >/dev/null 2>&1; then
        SSH_BASE=(sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
    else
        SSH_BASE=()
        log WARN "Pas de SSH_KEY ni sshpass - recherche titre impossible, passage direct au sync normal"
    fi

    if [ "${#SSH_BASE[@]}" -gt 0 ]; then
        # mindepth/maxdepth 2 = niveau "titre" (media/Categorie/Titre), pas les fichiers en dessous
        RAW_MATCHES=$("${SSH_BASE[@]}" "find media -mindepth 2 -maxdepth 2 -iname '*${FILTER}*' 2>/dev/null")

        while IFS= read -r remote_full_path; do
            [ -z "$remote_full_path" ] && continue

            MATCHED_KEY=""
            for k in "${ALL_KEYS[@]}"; do
                case "$remote_full_path" in
                    "$k"/*) MATCHED_KEY="$k" ;;
                esac
                [ -n "$MATCHED_KEY" ] && break
            done
            [ -z "$MATCHED_KEY" ] && continue

            local_folder="${MAPPINGS[$MATCHED_KEY]}"
            rel="${remote_full_path#"$MATCHED_KEY"/}"
            local_path="$LOCAL_BASE/$local_folder"

            TITLE_FOUND=1
            log INFO "Match titre: ~/$remote_full_path"
            mkdir -p "$local_path/$rel"
            TMP_OUT=$(mktemp)
            lftp -u "$REMOTE_USER,$REMOTE_PASS" sftp://$REMOTE_HOST << LFTPEOF 2>&1 | tee "$TMP_OUT" | while IFS= read -r line; do log INFO "  $line"; done
set ssl:verify-certificate no
set sftp:auto-confirm yes
set net:max-retries 3
set net:timeout 30
set xfer:use-temp-file yes
set xfer:temp-file-name ".*.lftp-tmp"
mirror --verbose --only-newer --continue "$remote_full_path" "$local_path/$rel"
bye
LFTPEOF
            RC_TITLE=${PIPESTATUS[0]}
            TITLE_OUT=$(cat "$TMP_OUT")
            rm -f "$TMP_OUT"
            if [ "$RC_TITLE" -eq 0 ]; then
                log INFO "OK titre '$rel'"
            else
                log ERROR "FAIL titre '$rel': $(echo "$TITLE_OUT" | tail -n 5 | tr '\n' ' | ')"
            fi
        done <<< "$RAW_MATCHES"
    fi

    [ "$TITLE_FOUND" -eq 0 ] && log WARN "Aucun titre trouve pour '$FILTER' - passage au sync normal"
    log INFO "Recherche titre terminee, reprise du sync normal complet"
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
        log WARN "Filtre '$FILTER' ne matche aucun dossier - ordre normal"
    else
        log INFO "Filtre '$FILTER' -> priorite: ${PRIORITY_KEYS[*]}"
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

    log INFO "Debut: ~/$remote_path -> $local_path"
    START_TS=$(date +%s)

    TMP_OUT=$(mktemp)
    lftp -u "$REMOTE_USER,$REMOTE_PASS" sftp://$REMOTE_HOST << LFTPEOF 2>&1 | tee "$TMP_OUT" | while IFS= read -r line; do log INFO "  $line"; done
set ssl:verify-certificate no
set sftp:auto-confirm yes
set net:max-retries 3
set net:timeout 30
set xfer:use-temp-file yes
set xfer:temp-file-name ".*.lftp-tmp"
mirror --verbose --only-newer --continue "$remote_path" "$local_path"
bye
LFTPEOF
    RC=${PIPESTATUS[0]}
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
    log INFO "FIN: $SUCCESS reussi, $FAIL echoue"
else
    log WARN "FIN: $SUCCESS reussi, $FAIL echoue -> ${FAILED_PATHS[*]}"
fi
