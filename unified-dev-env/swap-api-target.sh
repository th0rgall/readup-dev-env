#!/bin/bash
# Swap the web app's API target between LOCAL services and the PRODUCTION API
# (reached through the prodproxy.dev.readup.org CORS proxy — see nginx.conf).
#
# Usage:
#   swap-api-target.sh prod     # point web app at the prod API via the proxy
#   swap-api-target.sh local    # point web app back at local services
#   swap-api-target.sh status   # show the current target (default)
#
# What it changes:
#   - web/src/app/server/config.dev.json  (apiServer.host + cookieName)
#   - local PostgreSQL + API: stopped for prod, (re)started for local
#   - the web build is restarted so the new config takes effect (gulp only copies
#     config files at startup)
#
# IMPORTANT: this operates on the EXISTING `dev` zellij session and restarts
# services IN PLACE (kill the process, then re-run its command pane). It never
# kills/recreates the session, so it is safe to run from inside the session
# (e.g. the orchestrator pane) without disconnecting yourself.

set -euo pipefail

TARGET="${1:-status}"

READUP_DIR="$HOME/readup"
WEB_CONFIG="$READUP_DIR/web/src/app/server/config.dev.json"
PIDS_DIR="$HOME/.pids"
LOGS_DIR="$HOME/.logs"
SESSION="dev"
LAYOUT="$HOME/dev-layout.kdl"
PG_CTL="/usr/lib/postgresql/14/bin/pg_ctl"
PG_DATA="/var/lib/postgresql/14/main"
SESSION_CREATED=0

# Local vs prod-proxy config values.
LOCAL_API_HOST="api.dev.readup.org"
PROD_API_HOST="prodproxy.dev.readup.org"
LOCAL_COOKIE="devSessionKey"   # local ASP.NET API dev cookie
PROD_COOKIE="sessionKey"       # production API cookie (config.prod.json)

if [ ! -f "$WEB_CONFIG" ]; then
    echo "Error: web config not found: $WEB_CONFIG"
    echo "Have you run ~/bootstrap-repos.sh and configured the web repo?"
    exit 1
fi

current_target() {
    if [ "$(jq -r '.apiServer.host' "$WEB_CONFIG")" = "$PROD_API_HOST" ]; then
        echo "prod"
    else
        echo "local"
    fi
}

set_config() {
    # $1 = api host, $2 = cookie name
    local tmp
    tmp="$(mktemp)"
    jq --arg host "$1" --arg cookie "$2" \
        '.apiServer.host = $host | .cookieName = $cookie' \
        "$WEB_CONFIG" > "$tmp" && mv "$tmp" "$WEB_CONFIG"
}

# Active-session check. Querying the session directly avoids parsing
# `zellij list-sessions` output, which is ANSI-colored (breaks grep -w) and also
# lists EXITED sessions we couldn't write to anyway.
session_active() { zellij --session "$SESSION" action list-panes >/dev/null 2>&1; }

# Make sure the dev session is running. If it isn't, create it fresh from the
# layout (which starts api + web with whatever config is currently on disk — we
# always write the config BEFORE calling this). Sets SESSION_CREATED=1 if it had
# to create one, so callers can skip a redundant restart of freshly-started panes.
ensure_session() {
    if session_active; then
        SESSION_CREATED=0
        return 0
    fi
    echo "No active '$SESSION' zellij session — creating it (dev-layout.kdl)..."
    # A killed session lingers as EXITED; --create-background would resurrect it
    # with its old layout, so clear it first.
    zellij delete-session "$SESSION" --force 2>/dev/null || true
    zellij attach --create-background "$SESSION" options --default-layout "$LAYOUT"
    sleep 2
    SESSION_CREATED=1
}

# Resolve a zellij pane id (terminal_N) by its pane title. Works whether or not
# we are attached, and survives layout differences (no hard-coded ids).
pane_id_by_title() {
    local id
    id="$(zellij --session "$SESSION" action list-panes --json 2>/dev/null \
        | jq -r --arg t "$1" '.[] | select(.is_plugin == false and .title == $t) | .id' \
        | head -1)"
    [ -n "$id" ] && printf 'terminal_%s' "$id"
}

# Kill a service's process and wait for it to actually exit.
kill_service() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
}

# Restart a service in place: kill it, then press Enter in its command pane to
# re-run it (zellij re-runs an exited command pane on Enter = byte 13).
restart_service() {
    local pidfile="$1" title="$2" pane
    pane="$(pane_id_by_title "$title")"
    kill_service "$pidfile"
    if [ -n "$pane" ]; then
        zellij --session "$SESSION" action write --pane-id "$pane" 13
    else
        echo "  warning: no '$title' pane in session '$SESSION' — run ~/start.sh?"
    fi
}

postgres_running() { sudo -u postgres psql -c '\q' 2>/dev/null; }

stop_postgres() {
    if postgres_running; then
        echo "Stopping local PostgreSQL..."
        sudo -u postgres "$PG_CTL" -D "$PG_DATA" -m fast stop >/dev/null 2>&1 || true
    fi
}

start_postgres() {
    if ! postgres_running; then
        echo "Starting local PostgreSQL..."
        sudo -u postgres "$PG_CTL" -D "$PG_DATA" -l /var/log/postgresql/server.log start
        until postgres_running; do sleep 0.3; done
    fi
}

wait_for_web() {
    echo "Waiting for the web server (port 5001)..."
    for _ in $(seq 1 120); do
        ss -ltn 2>/dev/null | grep -q ":5001" && return 0
        sleep 1
    done
    echo "  (5001 not up yet — check: tail -n 50 $LOGS_DIR/web-build.log)"
}

if [ "$TARGET" = "status" ]; then
    echo "API target:     $(current_target)"
    echo "  apiServer.host: $(jq -r '.apiServer.host' "$WEB_CONFIG")"
    echo "  cookieName:     $(jq -r '.cookieName' "$WEB_CONFIG")"
    exit 0
fi

case "$TARGET" in
    prod|prodproxy)
        echo "→ Switching web app to the PRODUCTION API (via $PROD_API_HOST)"
        # 1. Always write the desired config first, so a later failure can't leave
        #    the target half-applied.
        set_config "$PROD_API_HOST" "$PROD_COOKIE"
        # 2. Local API + DB are not used against prod — shut them down.
        stop_postgres
        # 3. Make sure the session exists, then guarantee the web watcher restarts
        #    with the new config.
        ensure_session
        echo "Stopping local API..."
        kill_service "$PIDS_DIR/api.pid"
        rm -f "$PIDS_DIR/api.pid"
        echo "Restarting web build with the new config..."
        restart_service "$PIDS_DIR/web-build.pid" "web-build"
        ;;

    local)
        echo "→ Switching web app to LOCAL services"
        set_config "$LOCAL_API_HOST" "$LOCAL_COOKIE"
        start_postgres
        ensure_session
        # If we just created the session the api pane is already starting with the
        # new config; otherwise restart it so it picks the config up.
        if [ "$SESSION_CREATED" = "0" ]; then
            echo "Restarting local API..."
            restart_service "$PIDS_DIR/api.pid" "api"
        fi
        echo "Restarting web build with the new config..."
        restart_service "$PIDS_DIR/web-build.pid" "web-build"
        ;;

    *)
        echo "Usage: $(basename "$0") {local|prod|status}"
        exit 1
        ;;
esac

wait_for_web
echo "Reloading nginx..."
sudo nginx -s reload 2>/dev/null || true

echo ""
echo "Done. API target is now: $(current_target)"
if [ "$(current_target)" = "prod" ]; then
    echo "  Web app → https://dev.readup.org  → API https://api.readup.org (via $PROD_API_HOST)"
    echo "  Local API + PostgreSQL are stopped."
    echo "  NOTE: your HOST /etc/hosts must map $PROD_API_HOST → 127.0.0.1 for the browser."
else
    echo "  Web app → https://dev.readup.org  → API https://api.dev.readup.org (local)"
fi
