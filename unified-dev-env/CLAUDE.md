# Readup Dev Environment

## Repository layout

All Readup repositories live under `~/readup/`:

| Directory           | Contents                              | Default port |
|---------------------|---------------------------------------|--------------|
| `~/readup/api`      | ASP.NET Core API                      | 5000         |
| `~/readup/web`      | Node.js web app + gulp build system   | 5001         |
| `~/readup/db`       | PostgreSQL schema & seed scripts      | —            |
| `~/readup/static`   | Static assets served by nginx         | —            |
| `~/readup/dev-env`  | Dev environment config & scripts      | —            |

If `~/readup/` is empty, run `~/bootstrap-repos.sh` first, then configure each repo per its own README before running `~/start.sh`.

## Dev server management (tmux)

All dev servers MUST run in the persistent tmux session named `dev`.
Never run servers in the foreground or in Claude's own shell.

### Session window layout

| Window | Name          | Process                                        |
|--------|---------------|------------------------------------------------|
| 0      | `orchestrator`| Claude's working window (commands, edits)      |
| 1      | `api`         | `dotnet run` — ASP.NET Core API (port 5000)    |
| 2      | `web-build`   | `gulp watch:dev:app` — webpack build watcher   |

Run `~/start.sh` to bootstrap the session and start all services automatically.

### Manual bootstrap (if session is missing)
```bash
tmux new-session -d -s dev -n orchestrator
tmux new-window  -t dev -n api
tmux new-window  -t dev -n web-build
```

### Environment variables required for all web processes
```bash
NODE_ENV=development
NODE_EXTRA_CA_CERTS=/etc/ssl/dev.readup.org.cer
NODE_OPTIONS=--openssl-legacy-provider
```

### Starting a server
```bash
tmux send-keys -t dev:api \
  "cd ~/readup/api && ASPNETCORE_ENVIRONMENT=Development dotnet run --project api.csproj & echo \$! > ~/.pids/api.pid" \
  Enter
```

### Reading logs
```bash
tmux capture-pane -t dev:api        -p -S -200
tmux capture-pane -t dev:web-build  -p -S -200
```

### Killing / restarting a server
```bash
tmux send-keys -t dev:api "" ""   # send Ctrl-C
sleep 2
tmux send-keys -t dev:api \
  "ASPNETCORE_ENVIRONMENT=Development dotnet run --project api.csproj & echo \$! > ~/.pids/api.pid" \
  Enter
```

### Checking if a server is alive
```bash
tmux list-windows -t dev
tmux capture-pane -t dev:api -p | tail -5
```

Always capture pane output after starting servers to confirm they came up cleanly,
and re-check if an operation seems to have failed.

## PID files

All managed servers MUST write a PID file to `~/.pids/`.

| Service      | PID file                  |
|--------------|---------------------------|
| `api`        | `~/.pids/api.pid`         |
| `web-build`  | `~/.pids/web-build.pid`   |

### Liveness check
```bash
for svc in api web-build; do
  PID=$(cat ~/.pids/$svc.pid 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "$svc: running (pid $PID)"
  else
    echo "$svc: DOWN"
  fi
done
```

### Killing cleanly
```bash
PID=$(cat ~/.pids/api.pid)
kill "$PID" && rm ~/.pids/api.pid
```

### Restarting
```bash
PID=$(cat ~/.pids/api.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null; sleep 1
tmux send-keys -t dev:api \
  "cd ~/readup/api && ASPNETCORE_ENVIRONMENT=Development dotnet run --project api.csproj & echo \$! > ~/.pids/api.pid" \
  Enter
```

Run the liveness check before assuming any server is up, especially after edits
to related code or config.

## Services & URLs

After `~/start.sh` completes, the following URLs are available (requires port 443
on the container to be mapped to 443 on the host, and `/etc/hosts` entries on the
host machine):

| Service | URL                              |
|---------|----------------------------------|
| Web app | https://dev.readup.org           |
| API     | https://api.dev.readup.org       |
| Static  | https://static.dev.readup.org    |
| Blog    | https://blog.dev.readup.org      |

Required `/etc/hosts` entries on the **host machine**:
```
127.0.0.1  dev.readup.org  api.dev.readup.org  static.dev.readup.org  blog.dev.readup.org  article-test.dev.readup.org
```

## Database

- Host: `localhost:5432`
- Database: `rrit`
- User/password: `postgres` / `postgres`

### Restore sample data (PowerShell restore script)
```bash
cd ~/readup/db
pwsh dev-scripts/restore-sample.ps1
```

The script references the hardcoded path `/db/seed/sample-data.sql`. The
container entrypoint creates a `/db → ~/readup/db` symlink automatically
once the `db` repo is cloned.

## Important startup notes

- **PostgreSQL and nginx** are started automatically by the container entrypoint.
  `start.sh` checks they are up but does not own them.
- **First-time setup**: each repo needs its own configuration before `start.sh`
  will work. See the README in `~/readup/api` and `~/readup/web`.
