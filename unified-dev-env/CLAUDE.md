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

## Dev server management (zellij)

All dev servers MUST run in the persistent zellij session named `dev`.
Never run servers in the foreground or in Claude's own shell.

The `dev` session is **headless** (created in the background with no terminal
attached). Claude drives it entirely from its own shell with
`zellij --session dev action ...` — you do not attach to it.

> ⚠️ **NEVER kill or delete the whole `dev` session.** Claude's own shell runs
> *inside* the `dev` session (`zellij list-sessions` shows `dev … (current)`), so
> `zellij kill-session dev` / `zellij delete-session dev` — or any `pkill zellij` —
> **terminates Claude's own session along with it.** This has happened before.
> To recover a crashed or stuck server, **restart only its command pane in place**
> (kill the process via its PID file, then send Enter to re-run the pane — see
> "Killing / restarting a server" below). There is never a reason to tear down the
> session; if a full reset is truly unavoidable, ask the user to run
> `~/start.sh` from a shell outside the session rather than doing it yourself.

### Session tab / pane layout

The session is created from `~/dev-layout.kdl`. Panes get ids in creation order:

| Tab            | Pane id      | Process                                        |
|----------------|--------------|------------------------------------------------|
| `orchestrator` | `terminal_0` | Spare shell                                    |
| `api`          | `terminal_1` | `dotnet run` — ASP.NET Core API (port 5000)    |
| `web-build`    | `terminal_2` | `gulp watch:dev:app` — webpack build watcher   |

Pane ids are **0-based** (zellij numbers terminal panes from `terminal_0` in
creation order). Server output is redirected to `~/.logs/`, so the panes
themselves render blank — read logs from the files, not `dump-screen`.

The `api` and `web-build` panes are zellij **command panes**: each runs a single
command that writes its PID to `~/.pids/<svc>.pid` and tees output to
`~/.logs/<svc>.log`. When the command exits, pressing Enter in the pane re-runs it.

Run `~/start.sh` to start PostgreSQL, create the session (which starts the API and
web build watcher via the layout), and reload nginx — all automatically.

If the pane ids ever differ from the table above, confirm them with:
```bash
zellij --session dev action list-panes --json | jq
```

### Manual bootstrap (if the session is missing)
```bash
zellij attach --create-background dev options --default-layout ~/dev-layout.kdl
```

### Environment variables required for all web processes
These are already baked into `~/dev-layout.kdl`; set them only when running a web
process by hand:
```bash
NODE_ENV=development
NODE_EXTRA_CA_CERTS=/etc/ssl/dev.readup.org.cer
NODE_OPTIONS=--openssl-legacy-provider
```

### Reading logs
Prefer the log files (most reliable):
```bash
tail -n 200 ~/.logs/api.log
tail -f     ~/.logs/web-build.log
```
Dumping a server pane's scrollback is usually blank (output is redirected to the
log file above); it is mainly useful for the `orchestrator` shell:
```bash
zellij --session dev action dump-screen --pane-id terminal_0 --full
```

### Killing / restarting a server
Kill via the PID file, then re-run the command pane by sending Enter (byte 13):
```bash
kill "$(cat ~/.pids/api.pid)" 2>/dev/null; sleep 2
zellij --session dev action write --pane-id terminal_1 13   # Enter → re-run
```
(`web-build` is `terminal_2`.) To interrupt a running server without killing by
PID, send Ctrl-C (byte 3) to its pane: `zellij --session dev action write --pane-id terminal_1 3`.

### Sending an ad-hoc command to a pane
```bash
zellij --session dev action write-chars --pane-id terminal_0 "some command"
zellij --session dev action write       --pane-id terminal_0 13   # Enter
```

### Checking if the session is alive
```bash
zellij list-sessions
zellij --session dev action list-panes --json | jq
```

Always read the log file after starting a server to confirm it came up cleanly,
and re-check if an operation seems to have failed.

## PID files

Each server writes a PID file to `~/.pids/` (done automatically by the layout
command via `echo $$` before `exec`, so the PID is the server process itself).

| Service      | PID file                  | Pane         |
|--------------|---------------------------|--------------|
| `api`        | `~/.pids/api.pid`         | `terminal_1` |
| `web-build`  | `~/.pids/web-build.pid`   | `terminal_2` |

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
zellij --session dev action write --pane-id terminal_1 13   # Enter → re-run the pane
```

Run the liveness check before assuming any server is up, especially after edits
to related code or config.

## Services & URLs

After `~/start.sh` completes, the following URLs are available (requires port 443
on the container to be mapped to 443 on the host, and `/etc/hosts` entries on the
host machine):

| Service     | URL                                 |
|-------------|-------------------------------------|
| Web app     | https://dev.readup.org              |
| API         | https://api.dev.readup.org          |
| Static      | https://static.dev.readup.org       |
| Blog        | https://blog.dev.readup.org         |
| Prod proxy  | https://prodproxy.dev.readup.org    |

`prodproxy.dev.readup.org` is a CORS-avoiding reverse proxy to the **production**
API `https://api.readup.org` (see `nginx.conf`). It forwards everything but takes
over CORS, allowing browser requests from `https://dev.readup.org`. It is only
used when the web app is switched to the prod target — see "Switching the API
target" below.

Required `/etc/hosts` entries on the **host machine**:
```
127.0.0.1  dev.readup.org  api.dev.readup.org  static.dev.readup.org  blog.dev.readup.org  article-test.dev.readup.org  prodproxy.dev.readup.org
```

The **same entries are also required inside the container**: the web app's
server-side renderer fetches `https://api.dev.readup.org` (and static/web, and
`prodproxy.dev.readup.org` in prod mode) by hostname, and nginx terminates TLS for
them on 443 in this container. The entrypoint adds them to the container's
`/etc/hosts` (→ `127.0.0.1`) at startup.

The dev TLS cert (`/etc/ssl/dev.readup.org.cer`) must cover every hostname above.
It is an mkcert-signed **wildcard** leaf (`dev.readup.org` + `*.dev.readup.org`)
bundled with the mkcert rootCA, so `NODE_EXTRA_CA_CERTS` (which points at that same
file) trusts the chain and no per-host re-trust is needed.

## Switching the API target (local ↔ production)

`~/readup/swap-api-target.sh` switches the web app between local services and the
production API (reached via the `prodproxy.dev.readup.org` proxy). It edits
`web/src/app/server/config.dev.json` (`apiServer.host` + `cookieName`), then
restarts the affected services **in place** — it never kills/recreates the `dev`
session, so it is safe to run from inside the session (e.g. the orchestrator pane)
without disconnecting yourself.

```bash
~/readup/swap-api-target.sh status   # show current target
~/readup/swap-api-target.sh prod      # → prod API; stops local API + PostgreSQL,
                                       #   restarts web build in place
~/readup/swap-api-target.sh local     # → local services; starts PostgreSQL,
                                       #   restarts api + web build in place
```

Every invocation **always writes the desired config first** and **always restarts
the web watcher**, so the running server can never drift from the config on disk
(gulp only reads config at startup — changing the file without a restart leaves the
old target live at runtime). If no `dev` session is active, the script creates one
from `dev-layout.kdl` first.

How the in-place restart works: it finds a service's pane by title
(`list-panes --json`), kills the process via its PID file, then sends Enter
(`write ... 13`) to re-run the exited command pane. In **prod** mode the `api`
pane is left exited (its process killed); `swap local` re-runs it. The session
always uses `dev-layout.kdl`, so pane ids don't shift between modes.

Notes:
- Prod mode needs the browser's HOST `/etc/hosts` to map `prodproxy.dev.readup.org`
  → `127.0.0.1`, and the cert to cover it (both handled by the wildcard cert above).
- Auth against prod is best-effort: `cookieName` is swapped to `sessionKey` and the
  proxy re-scopes prod cookies from `.readup.org` to `.dev.readup.org`.

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

## Troubleshooting: `502 Bad Gateway` on https://dev.readup.org

`dev.readup.org` proxies to the web SSR server on `127.0.0.1:5001`. A 502 means
nothing is listening there. Note that `web-build` (gulp `watch:dev:app`) both
rebuilds bundles **and** spawns the Node server (`app/server/main.js`) after each
successful server compile — there is no separate server process.

Common causes:
- **The SSR server crashed.** It fetches the API by hostname during render; if the
  request errors, `ServerApi.js` throws an unhandled `TypeError` and the process
  dies. Check `~/.logs/web-build.log`. Ensure the in-container `/etc/hosts` entries
  above exist (`getent hosts api.dev.readup.org` → `127.0.0.1`).
- **The watcher can't relaunch it.** `tsc-watch` only restarts the server on the
  next successful *recompile*, and after a runtime crash even that can fail to
  relaunch. **Restart the `web-build` command pane in place** — do NOT kill the
  session (that kills Claude's own session too; see the warning above):
  ```bash
  kill "$(cat ~/.pids/web-build.pid)" 2>/dev/null; sleep 2
  zellij --session dev action write --pane-id terminal_2 13   # Enter → re-run pane
  ```
  If the process already exited, the pane just needs the Enter to re-run. Only if
  an in-place restart repeatedly fails should you ask the user to run `~/start.sh`
  from a shell **outside** the `dev` session.
  Verify: `ss -ltn | grep 5001` and
  `curl -sk -o /dev/null -w '%{http_code}\n' https://dev.readup.org/ --resolve dev.readup.org:443:127.0.0.1`
