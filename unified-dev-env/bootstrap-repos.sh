#!/bin/bash
# Bootstrap readup repositories from a config file.
#
# Usage:
#   ~/bootstrap-repos.sh                     # uses ~/repos.conf (default)
#   ~/bootstrap-repos.sh /path/to/repos.conf # custom config
#
# Config file format (whitespace-separated, one repo per line):
#   <local-path>  <git-url>  [branch]
#
#   local-path — directory name under ~/readup/ where the repo will be cloned
#   branch     — optional; if omitted, the remote's default branch is used
#   Lines starting with # and blank lines are ignored.

set -euo pipefail

CONFIG_FILE="${1:-$HOME/repos.conf}"
BASE_DIR="$HOME/readup"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE"
    echo "Usage: $0 [config-file]"
    exit 1
fi

echo "Bootstrapping readup repos from: $CONFIG_FILE"
echo "Destination base:                $BASE_DIR"
echo ""

mkdir -p "$BASE_DIR"

while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse: <path>  <url>  [branch]
    read -r rel_path url branch_arg <<< "$line"
    dest="$BASE_DIR/$rel_path"

    if [ -d "$dest/.git" ]; then
        echo "  skip   $rel_path  (already cloned at $dest)"
        continue
    fi

    if [ -n "${branch_arg:-}" ]; then
        echo "  clone  $rel_path  ←  $url  (branch: $branch_arg)"
        git clone --branch "$branch_arg" "$url" "$dest"
    else
        echo "  clone  $rel_path  ←  $url"
        git clone "$url" "$dest"
    fi
done < "$CONFIG_FILE"

echo ""
echo "Done. Repos are at $BASE_DIR/"

# ── /db symlink ───────────────────────────────────────────────────────────────
# Needed by db/dev-scripts/restore-sample.ps1 which references the hardcoded
# Docker path /db/seed/sample-data.sql.
if [ -d "$BASE_DIR/db" ] && [ ! -e /db ]; then
    echo "Creating /db -> $BASE_DIR/db symlink (requires sudo)..."
    sudo ln -sf "$BASE_DIR/db" /db
fi

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
# Place a copy in ~/readup/ so Claude Code finds it when working inside any
# repo subdirectory.
if [ -f "$HOME/CLAUDE.md" ]; then
    cp "$HOME/CLAUDE.md" "$BASE_DIR/CLAUDE.md"
    echo "Copied CLAUDE.md -> $BASE_DIR/CLAUDE.md"
fi

# ── Web initial setup ────────────────────────────────────────────────────────
WEB_DIR="$BASE_DIR/web"
if [ -d "$WEB_DIR" ]; then
    echo ""
    echo "Setting up web (npm ci)..."
    (cd "$WEB_DIR" && npm ci)
fi

# ── DB initial setup ──────────────────────────────────────────────────────────
DB_DIR="$BASE_DIR/db"
if [ -d "$DB_DIR" ]; then
    echo ""
    echo "Restoring sample database (rrit)..."
    # restore-sample.ps1 references schema.sql relative to cwd, so set -WorkingDirectory.
    # Run as dev user with PG* env vars (TCP + password) instead of sudo -u postgres,
    # since postgres can't traverse /home/dev/. The script resets search_path to 'core'
    # only; re-apply the 'core, article_api' fix required by Npgsql type mapping.
    PGUSER=postgres PGPASSWORD=postgres PGHOST=localhost \
        pwsh -WorkingDirectory "$DB_DIR" -File "$DB_DIR/dev-scripts/restore-sample.ps1" -DbName rrit
    PGPASSWORD=postgres psql -U postgres -h localhost \
        -c "ALTER DATABASE rrit SET search_path TO core, article_api;"
fi

# ── API initial setup ─────────────────────────────────────────────────────────
API_DIR="$BASE_DIR/api"
if [ -d "$API_DIR" ]; then
    echo ""
    echo "Setting up api..."

    # appsettings.json — from Docker template, adjusted for localhost services
    if [ ! -f "$API_DIR/appsettings.json" ]; then
        sed \
            -e 's/Host=readup-db/Host=localhost/g' \
            -e 's/"Host": "readup-mail"/"Host": "localhost"/g' \
            "$API_DIR/appsettings.docker.json" > "$API_DIR/appsettings.json"
        echo "  created api/appsettings.json (from appsettings.docker.json)"
    else
        echo "  skip api/appsettings.json (already exists)"
    fi

    # hostsettings.json — copied as-is from Docker template
    if [ ! -f "$API_DIR/hostsettings.json" ]; then
        cp "$API_DIR/hostsettings.docker.json" "$API_DIR/hostsettings.json"
        echo "  created api/hostsettings.json (from hostsettings.docker.json)"
    else
        echo "  skip api/hostsettings.json (already exists)"
    fi
fi
