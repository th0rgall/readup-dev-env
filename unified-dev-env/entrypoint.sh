#!/bin/bash
set -euo pipefail

PG_VERSION=14
PG_DATA="/var/lib/postgresql/$PG_VERSION/main"
PG_CTL="/usr/lib/postgresql/$PG_VERSION/bin/pg_ctl"
PG_INITDB="/usr/lib/postgresql/$PG_VERSION/bin/initdb"

# ── VS Code Server volume ownership ───────────────────────────────────────────
# ~/.vscode-server is an anonymous volume (docker-compose.yml). If Docker created
# it empty as root:root, the dev user can't install the VS Code Server into it on
# attach ("mkdir: Permission denied"). Self-heal the ownership if it's not dev's.
VSCODE_SERVER_DIR=/home/dev/.vscode-server
if [ -d "$VSCODE_SERVER_DIR" ] && [ "$(stat -c '%U' "$VSCODE_SERVER_DIR")" != "dev" ]; then
    echo "[init] Fixing ownership of $VSCODE_SERVER_DIR -> dev:dev"
    chown dev:dev "$VSCODE_SERVER_DIR"
fi

# ── PostgreSQL ────────────────────────────────────────────────────────────────
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "[init] Initializing PostgreSQL $PG_VERSION cluster..."
    install -d -o postgres -g postgres -m 700 "$PG_DATA"
    sudo -u postgres "$PG_INITDB" \
        -D "$PG_DATA" \
        --auth-local peer \
        --auth-host scram-sha-256
fi

echo "[init] Starting PostgreSQL $PG_VERSION..."
sudo -u postgres "$PG_CTL" -D "$PG_DATA" -l /var/log/postgresql/server.log start

# Wait until PostgreSQL accepts connections
until sudo -u postgres psql -c '\q' 2>/dev/null; do
    sleep 0.3
done

# Set postgres password (idempotent)
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';" 2>/dev/null || true

# Create rrit database if it doesn't exist yet
if ! sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw rrit; then
    echo "[init] Creating rrit database..."
    sudo -u postgres psql -c "CREATE DATABASE rrit;"
    # Required for Npgsql composite type mapping (see notes in Dockerfile)
    sudo -u postgres psql -c "ALTER DATABASE rrit SET search_path TO core, article_api;"
fi

# ── /db symlink ───────────────────────────────────────────────────────────────
# The PowerShell restore script (db/dev-scripts/restore-sample.ps1) references
# the hardcoded Docker path /db/seed/sample-data.sql. Create a symlink so the
# script works without modification.
if [ -d /home/dev/readup/db ] && [ ! -e /db ]; then
    ln -sf /home/dev/readup/db /db
    echo "[init] Created /db -> /home/dev/readup/db symlink."
fi

# ── /etc/hosts for in-container SSR ───────────────────────────────────────────
# The web app's server-side renderer calls the API/static/web services by
# hostname (see web/src/app/server/config.dev.json). nginx terminates TLS for all
# of them on 443 inside this same container, so resolve them to localhost.
# Without this the SSR fetch fails and the web server (port 5001) crashes → 502.
if ! grep -q "api.dev.readup.org" /etc/hosts; then
    echo "[init] Adding *.dev.readup.org -> 127.0.0.1 to /etc/hosts"
    echo "127.0.0.1 dev.readup.org api.dev.readup.org static.dev.readup.org blog.dev.readup.org article-test.dev.readup.org prodproxy.dev.readup.org" >> /etc/hosts
fi

# ── nginx ─────────────────────────────────────────────────────────────────────
echo "[init] Starting nginx..."
nginx

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Readup unified dev environment ready                         │"
echo "│                                                               │"
echo "│  Attach with VS Code Dev Containers (via the Docker socket).  │"
echo "│                                                               │"
echo "│  Bootstrap repos  →  ~/bootstrap-repos.sh                    │"
echo "│                                                               │"
echo "│  Readup HTTPS  →  https://dev.readup.org  (after hosts setup) │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# Keep the container alive as PID 1. The VS Code Dev Containers extension attaches
# over the Docker socket (docker exec), so there is no foreground server to run.
exec sleep infinity
