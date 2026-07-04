#!/bin/bash
# Start all Readup dev services in a persistent tmux session.
#
# Usage:
#   ~/start.sh        # start everything
#
# Prerequisites:
#   - Repos cloned under ~/readup/ (run ~/bootstrap-repos.sh if not)
#   - API and web repos configured per their own READMEs
#   - Container started with port 443 mapped to host port 443

set -euo pipefail

READUP_DIR="$HOME/readup"
PIDS_DIR="$HOME/.pids"
SESSION="dev"

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [ ! -d "$READUP_DIR/api" ] || [ ! -d "$READUP_DIR/web" ]; then
    echo "Error: repos not found under $READUP_DIR"
    echo "Run ~/bootstrap-repos.sh first, then configure the repos per their READMEs."
    exit 1
fi

mkdir -p "$PIDS_DIR"

# ── tmux session ───────────────────────────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Creating tmux session '$SESSION'..."
    tmux new-session -d -s "$SESSION" -n orchestrator
    tmux new-window  -t "$SESSION" -n api
    tmux new-window  -t "$SESSION" -n web-build
else
    echo "Reusing existing tmux session '$SESSION'."
fi

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

# ── API ────────────────────────────────────────────────────────────────────────
echo "Starting API..."
tmux send-keys -t "$SESSION:api" \
    "cd $READUP_DIR/api && ASPNETCORE_ENVIRONMENT=Development dotnet run --project api.csproj & echo \$! > $PIDS_DIR/api.pid" \
    Enter

# ── Web build watcher ──────────────────────────────────────────────────────────
echo "Starting web build watcher..."
tmux send-keys -t "$SESSION:web-build" \
    "cd $READUP_DIR/web && NODE_ENV=development NODE_EXTRA_CA_CERTS=/etc/ssl/dev.readup.org.cer NODE_OPTIONS=--openssl-legacy-provider npx gulp watch:dev:app & echo \$! > $PIDS_DIR/web-build.pid" \
    Enter

# ── Wait for initial bundle before starting the server ────────────────────────
echo "Waiting 25s for initial web bundle compilation..."
echo "(Watch progress: tmux attach -t $SESSION -w web-build)"
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
        echo "  $svc: DOWN — check: tmux attach -t $SESSION -w $svc"
    fi
done

echo ""
echo "Readup is starting up:"
echo "  Web:    https://dev.readup.org"
echo "  API:    https://api.dev.readup.org"
echo "  Static: https://static.dev.readup.org"
echo ""
echo "Attach to session:  tmux attach -t $SESSION"
echo "Read logs:          tmux capture-pane -t $SESSION:<window> -p -S -200"
