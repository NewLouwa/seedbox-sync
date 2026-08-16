#!/bin/bash

PAUSE_FLAG="/opt/scripts/seedbox-sync/PAUSED"
PID_FILE="/tmp/ass-sync.pid"
MONITOR_PID_FILE="/tmp/ass-sync-monitors.pid"
LOCK_DIR="/tmp/ass.lock.d"

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
    pause)
        touch "$PAUSE_FLAG"
        warn "Sync PAUSE (bloque les prochains lancements, n'arrete pas un run en cours)"
        ;;
    resume)
        rm -f "$PAUSE_FLAG"
        ok "Sync RESUME"
        ;;
    test)
        set -a
        source /etc/seedbox-sync.env
        set +a
        info "Test de connexion vers $REMOTE_HOST..."
        OUT=$(lftp -u "$REMOTE_USER,$REMOTE_PASS" sftp://$REMOTE_HOST -e "set ssl:verify-certificate no; set net:max-retries 1; set net:timeout 15; ls; bye" 2>&1)
        RC=$?
        if [ "$RC" -eq 0 ]; then
            ok "OK - connexion et auth valides"
        else
            err "ECHEC (rc=$RC)"
            echo "$OUT" | tail -n 10
        fi
        ;;
    find)
        NAME="${2:-}"
        if [ -z "$NAME" ]; then
            echo "Usage: $0 find <nom>"
            exit 1
        fi
        set -a
        source /etc/seedbox-sync.env
        set +a

        if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
            SSH_BASE=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
        elif command -v sshpass >/dev/null 2>&1; then
            SSH_BASE=(sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$REMOTE_USER@$REMOTE_HOST")
        else
            err "Pas de SSH_KEY dans /etc/seedbox-sync.env ni de sshpass installe - recherche impossible"
            echo "Configure une cle SSH (recommande) ou: apt install -y sshpass"
            exit 1
        fi

        info "Recherche recursive de '$NAME' via SSH..."
        RESULTS=$("${SSH_BASE[@]}" "find media -iname '*${NAME}*' 2>/dev/null")
        RC=$?
        if [ "$RC" -ne 0 ]; then
            err "Echec connexion SSH (rc=$RC)"
            exit 1
        fi
        if [ -z "$RESULTS" ]; then
            warn "Aucun resultat"
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
            err "Deja actif (PID $PID) - utilise 'stop' d'abord ou attends la fin"
            exit 1
        fi
        info "Lancement manuel${FILTER:+ (priorite: $FILTER)}..."
        nohup env FORCE_RUN=1 SOURCE=manual /opt/scripts/seedbox-sync/scripts/sync.sh "$FILTER" >> /var/log/cron-sync.log 2>&1 &
        disown
        ok "Lance en arriere-plan, PID $!"
        echo "Suivi: tail -f /var/log/ass-sync.log"
        ;;
    stop)
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            warn "Arret de sync.sh (PID $PID)..."
            kill -TERM "$PID"
            sleep 2
            kill -0 "$PID" 2>/dev/null && { err "Toujours actif, kill -9"; kill -9 "$PID"; }
        else
            info "Aucun sync.sh actif (PID file absent ou obsolete)"
        fi
        if pkill -f "lftp -u.*sftp://" 2>/dev/null; then
            warn "Process lftp actif tue"
        fi
        if [ -f "$MONITOR_PID_FILE" ]; then
            while IFS= read -r mpid; do
                [ -z "$mpid" ] && continue
                if kill -0 "$mpid" 2>/dev/null; then
                    kill -9 "$mpid" 2>/dev/null
                    warn "Monitor de progression orphelin tue (PID $mpid)"
                fi
            done < "$MONITOR_PID_FILE"
        fi
        rm -rf "$LOCK_DIR" "$PID_FILE" "$MONITOR_PID_FILE"
        ok "Lock et PID nettoyes"
        ;;
    status)
        if [ -f "$PAUSE_FLAG" ]; then
            warn "Sync EN PAUSE (pas de nouveaux lancements)"
        else
            ok "Sync ACTIF (pause non appliquee)"
        fi
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            info "Run en cours: PID $PID"
        else
            echo "Aucun run en cours"
        fi
        ;;
    *)
        echo "Usage: $0 {test|find <nom>|start [filtre]|pause|resume|stop|status}"
        exit 1
        ;;
esac
