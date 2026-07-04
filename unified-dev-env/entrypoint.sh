#!/bin/bash
set -euo pipefail

PG_VERSION=14
PG_DATA="/var/lib/postgresql/$PG_VERSION/main"
PG_CTL="/usr/lib/postgresql/$PG_VERSION/bin/pg_ctl"
PG_INITDB="/usr/lib/postgresql/$PG_VERSION/bin/initdb"

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

# ── SSH deploy key ─────────────────────────────────────────────────────────────
# Volume-map your own key to /home/dev/.ssh/id_ed25519 to skip generation.
# Example: -v ~/.ssh/readup-deploy:/home/dev/.ssh/id_ed25519:ro
SSH_KEY=/home/dev/.ssh/id_ed25519
if [ ! -f "$SSH_KEY" ]; then
    echo "[init] No SSH key found — generating one..."
    install -d -o dev -g dev -m 700 /home/dev/.ssh
    sudo -u dev ssh-keygen -t ed25519 -C "readup-dev@$(hostname)" \
        -f "$SSH_KEY" -N ""
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Generated SSH public key (add to GitHub for git push):"
    echo "══════════════════════════════════════════════════════════"
    cat "${SSH_KEY}.pub"
    echo "══════════════════════════════════════════════════════════"
    echo ""
fi

# ── nginx ─────────────────────────────────────────────────────────────────────
echo "[init] Starting nginx..."
nginx

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Readup unified dev environment ready                         │"
echo "│                                                               │"
echo "│  VS Code Remote SSH  →  ssh dev@localhost -p <mapped-port>   │"
echo "│    user: dev  /  password: dev                                │"
echo "│                                                               │"
echo "│  Bootstrap repos  →  ~/bootstrap-repos.sh                    │"
echo "│                                                               │"
echo "│  Readup HTTPS  →  https://dev.readup.org  (after hosts setup) │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# Run sshd in the foreground — this keeps the container alive and provides
# the VS Code Remote SSH connection point.
exec /usr/sbin/sshd -D
