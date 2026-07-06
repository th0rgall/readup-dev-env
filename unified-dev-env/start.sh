#!/bin/bash
# Start all Readup dev services in a persistent, headless zellij session.
#
# Usage:
#   ~/start.sh        # start everything
#
# Prerequisites:
#   - Repos cloned under ~/readup/ (run ~/bootstrap-repos.sh if not)
#   - API and web repos configured per their own READMEs
#   - Container started with port 443 mapped to host port 443
#
# The zellij session "dev" is created from ~/dev-layout.kdl, which starts the API
# and web build watcher in their own tabs (panes terminal_1 and terminal_2). Each
# server writes a PID file to ~/.pids/ and logs to ~/.logs/. See CLAUDE.md.

set -euo pipefail

READUP_DIR="$HOME/readup"
PIDS_DIR="$HOME/.pids"
LOGS_DIR="$HOME/.logs"
SESSION="dev"
LAYOUT="$HOME/dev-layout.kdl"

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [ ! -d "$READUP_DIR/api" ] || [ ! -d "$READUP_DIR/web" ]; then
    echo "Error: repos not found under $READUP_DIR"
    echo "Run ~/bootstrap-repos.sh first, then configure the repos per their READMEs."
    exit 1
fi

mkdir -p "$PIDS_DIR" "$LOGS_DIR"

# ── PostgreSQL ─────────────────────────────────────────────────────────────────
# Normally started by the container entrypoint; verify it's up before proceeding.
if ! sudo -u postgres psql -c '\q' 2>/dev/null; then
    echo "PostgreSQL not running — starting..."
    sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl \
        -D /var/lib/postgresql/14/main \
        -l /var/log/postgresql/server.log start
    until sudo -u postgres psql -c '\q' 2>/dev/null; do sleep 0.3; done
fi
echo "PostgreSQL: OK"

# /db symlink is needed by db/dev-scripts/restore-sample.ps1
if [ -d "$READUP_DIR/db" ] && [ ! -e /db ]; then
    sudo ln -sf "$READUP_DIR/db" /db
fi

# ── zellij session (starts API + web build watcher via the layout) ─────────────
# Query the session directly (ANSI-colored `list-sessions` output breaks grep -w).
if zellij --session "$SESSION" action list-panes >/dev/null 2>&1; then
    echo "Reusing existing zellij session '$SESSION'."
else
    echo "Creating headless zellij session '$SESSION' (starts api + web-build)..."
    # Clear any EXITED session of the same name first: `attach --create-background`
    # would otherwise resurrect it with its old layout instead of $LAYOUT.
    zellij delete-session "$SESSION" --force 2>/dev/null || true
    zellij attach --create-background "$SESSION" options --default-layout "$LAYOUT"
fi

# ── Wait for initial bundle before reloading nginx ─────────────────────────────
echo "Waiting 25s for initial web bundle compilation..."
echo "(Watch progress: tail -f $LOGS_DIR/web-build.log)"
sleep 25

# ── nginx ──────────────────────────────────────────────────────────────────────
echo "Reloading nginx..."
sudo nginx -s reload 2>/dev/null || sudo nginx

# ── Liveness check ─────────────────────────────────────────────────────────────
sleep 3
echo ""
echo "Service status:"
for svc in api web-build; do
    PID=$(cat "$PIDS_DIR/$svc.pid" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "  $svc: running (pid $PID)"
    else
        echo "  $svc: DOWN — check: tail -n 50 $LOGS_DIR/$svc.log"
    fi
done

echo ""
echo "Readup is starting up:"
echo "  Web:    https://dev.readup.org"
echo "  API:    https://api.dev.readup.org"
echo "  Static: https://static.dev.readup.org"
echo ""
echo "Attach to session:  zellij attach $SESSION"
echo "Read logs:          tail -f $LOGS_DIR/<service>.log"
