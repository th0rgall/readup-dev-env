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
#
# Idempotent: safe to re-run (e.g. via devcontainer postCreateCommand on every
# rebuild). Existing repo clones are never touched or recreated — if a repo's
# origin or checked-out branch no longer match repos.conf, this only WARNS, it
# never force-changes the working copy. The sample-database restore is also
# skipped if the database already looks seeded, since it is destructive
# (drops and recreates the database).

set -euo pipefail

CONFIG_FILE="${1:-$HOME/repos.conf}"
BASE_DIR="$HOME/readup"

# GitHub credentials for HTTPS cloning (see .env / docker-compose env_file).
# When GITHUB_TOKEN is set, plain https://github.com/... URLs are cloned with a
# user:password remote of the form https://<user>:<token>@github.com/...
GITHUB_USER="${GITHUB_USER:-x-access-token}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Rewrite a plain GitHub HTTPS URL to embed credentials. URLs that already carry
# credentials (https://user:pass@github.com/...) or non-GitHub URLs pass through
# unchanged, so a repos.conf line may also hard-code its own credentials.
inject_credentials() {
    local url="$1"
    if [ -n "$GITHUB_TOKEN" ] && [[ "$url" == https://github.com/* ]]; then
        printf 'https://%s:%s@github.com/%s' \
            "$GITHUB_USER" "$GITHUB_TOKEN" "${url#https://github.com/}"
    else
        printf '%s' "$url"
    fi
}

# Normalize a git URL for comparison: drop scheme, embedded credentials, and a
# trailing ".git"/slash, so "https://x:tok@github.com/a/b.git" and
# "https://github.com/a/b" compare equal.
normalize_git_url() {
    local url="$1"
    url="${url#*://}"
    url="${url#*@}"
    url="${url%.git}"
    url="${url%/}"
    printf '%s' "$url"
}

# Warn (never modify) if an already-cloned repo's origin or branch drifted from
# repos.conf. $1=dest dir, $2=expected url, $3=expected branch (may be empty).
warn_if_mismatch() {
    local dest="$1" expected_url="$2" expected_branch="$3" actual_url actual_branch
    actual_url="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
    if [ -n "$actual_url" ] && [ "$(normalize_git_url "$actual_url")" != "$(normalize_git_url "$expected_url")" ]; then
        echo "    warning: origin is '$actual_url', repos.conf expects '$expected_url'"
    fi
    if [ -n "$expected_branch" ]; then
        actual_branch="$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [ -n "$actual_branch" ] && [ "$actual_branch" != "$expected_branch" ]; then
            echo "    warning: on branch '$actual_branch', repos.conf expects '$expected_branch'"
        fi
    fi
}

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
        warn_if_mismatch "$dest" "$url" "${branch_arg:-}"
        continue
    fi

    # Clone with credentials embedded, but log only the clean URL so the token
    # never lands in build/console output.
    clone_url="$(inject_credentials "$url")"
    if [ -n "${branch_arg:-}" ]; then
        echo "  clone  $rel_path  ←  $url  (branch: $branch_arg)"
        git clone --branch "$branch_arg" "$clone_url" "$dest"
    else
        echo "  clone  $rel_path  ←  $url"
        git clone "$clone_url" "$dest"
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

# ── API-target swap script ────────────────────────────────────────────────────
# Place the swap script in ~/readup/ so it lives next to the repos it operates on.
if [ -f "$HOME/swap-api-target.sh" ]; then
    cp "$HOME/swap-api-target.sh" "$BASE_DIR/swap-api-target.sh"
    chmod +x "$BASE_DIR/swap-api-target.sh"
    echo "Copied swap-api-target.sh -> $BASE_DIR/swap-api-target.sh"
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
    # restore-sample.ps1 does `DROP DATABASE IF EXISTS rrit WITH (FORCE)` before
    # reseeding, so it is destructive. Only run it the first time (schema 'core'
    # absent) — never on a re-run, or every rebuild would wipe local dev data.
    already_seeded="$(PGPASSWORD=postgres psql -U postgres -h localhost -d rrit -tAc \
        "SELECT 1 FROM information_schema.schemata WHERE schema_name='core'" 2>/dev/null || true)"
    if [ "$already_seeded" = "1" ]; then
        echo "skip   rrit database (schema 'core' already present — already seeded)"
    else
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
