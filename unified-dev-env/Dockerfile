# Readup Unified Development Environment
#
# A single Ubuntu 24.04 container containing all services needed for local Readup
# development: PostgreSQL 14, .NET 10, Node 22, nginx (SSL proxy), PowerShell,
# and Claude Code.
#
# VS Code access: this image is intended to be used as a Dev Container (see
# .devcontainer/devcontainer.json). The VS Code Dev Containers extension attaches
# to the running container through the Docker socket — no SSH server required.
# The VS Code Server and extensions are installed on first attach and cached in an
# anonymous volume (see docker-compose.yml), so they are NOT baked into this image.
#
# Build context must be the dev-env repo root so the SSL certs can be copied in.
# Normally you don't build directly — the Dev Container / docker-compose does it —
# but the equivalent manual build is:
#
#   docker build -f unified-dev-env/Dockerfile -t readup-dev .
#
# Bootstrap repos once inside the container:
#   ~/bootstrap-repos.sh              # uses the bundled default repos.conf
#   ~/bootstrap-repos.sh /path/to/repos.conf   # or provide your own

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV NVM_DIR=/home/dev/.nvm

# ── Locale + base system tools ────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
	locales \
	curl \
	wget \
	git \
	build-essential \
	ca-certificates \
	gnupg \
	lsb-release \
	sudo \
	unzip \
	jq \
	openssh-client \
	&& locale-gen en_US.UTF-8 \
	&& rm -rf /var/lib/apt/lists/*

# ── PostgreSQL 14 ─────────────────────────────────────────────────────────────
# Ubuntu 24.04 ships PG 16 by default; install PG 14 from apt.postgresql.org.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
	| gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
	&& echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
	> /etc/apt/sources.list.d/pgdg.list \
	&& apt-get update && apt-get install -y postgresql-14 \
	&& rm -rf /var/lib/apt/lists/* \
	# Remove the package-created cluster so entrypoint.sh owns initialization.
	# This allows volume-mounting /var/lib/postgresql/14/main for data persistence.
	&& rm -rf /var/lib/postgresql/14/main

# ── .NET 10 SDK ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
	-o /tmp/ms-prod.deb \
	&& dpkg -i /tmp/ms-prod.deb \
	&& rm /tmp/ms-prod.deb \
	&& apt-get update && apt-get install -y dotnet-sdk-10.0 \
	&& rm -rf /var/lib/apt/lists/*

# ── PowerShell 7 (direct tarball — avoids Microsoft apt amd64-only package) ──
# The Microsoft apt repo ships powershell:amd64 only, which fails on arm64.
# GitHub releases provide proper arm64 builds.
RUN ARCH=$(uname -m) \
	&& case "$ARCH" in \
	x86_64)  PWSH_ARCH="x64"   ;; \
	aarch64) PWSH_ARCH="arm64" ;; \
	*) echo "Unsupported arch: $ARCH" && exit 1 ;; \
	esac \
	&& PWSH_VERSION=$(curl -s https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
	| jq -r '.tag_name' | sed 's/v//') \
	&& echo "Installing PowerShell $PWSH_VERSION for $PWSH_ARCH" \
	&& curl -sL \
	"https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${PWSH_ARCH}.tar.gz" \
	-o /tmp/powershell.tar.gz \
	&& mkdir -p /opt/microsoft/powershell/7 \
	&& tar -xz -C /opt/microsoft/powershell/7 -f /tmp/powershell.tar.gz \
	&& chmod +x /opt/microsoft/powershell/7/pwsh \
	&& ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
	&& rm /tmp/powershell.tar.gz

# ── nginx ─────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y nginx && rm -rf /var/lib/apt/lists/*

# ── zellij (terminal multiplexer) ─────────────────────────────────────────────
# Not in Ubuntu apt; install the static musl binary from GitHub releases.
# Used to run the dev servers in a persistent, headless (background) session
# that Claude drives via `zellij --session dev action ...` (see CLAUDE.md).
RUN ARCH=$(uname -m) \
	&& case "$ARCH" in \
	x86_64)  ZELLIJ_TARGET="x86_64-unknown-linux-musl"  ;; \
	aarch64) ZELLIJ_TARGET="aarch64-unknown-linux-musl" ;; \
	*) echo "Unsupported arch: $ARCH" && exit 1 ;; \
	esac \
	&& curl -sL \
	"https://github.com/zellij-org/zellij/releases/latest/download/zellij-${ZELLIJ_TARGET}.tar.gz" \
	-o /tmp/zellij.tar.gz \
	&& tar -xz -C /usr/local/bin -f /tmp/zellij.tar.gz zellij \
	&& chmod +x /usr/local/bin/zellij \
	&& rm /tmp/zellij.tar.gz

# ── dev user ──────────────────────────────────────────────────────────────────
# The VS Code Dev Containers extension attaches as this user over the Docker
# socket (remoteUser in devcontainer.json), so no password / SSH login is needed.
RUN useradd -m -s /bin/bash dev \
	&& echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
	# Allow nginx (www-data) to traverse /home/dev to serve static files.
	# useradd creates home dirs as 750; www-data needs the world-execute bit.
	&& chmod o+x /home/dev \
	&& mkdir -p /var/log/postgresql

# ── SSL certificates (for nginx HTTPS proxy) ──────────────────────────────────
# Build context = dev-env repo root.
COPY ssl/dev.readup.org.cer /etc/ssl/dev.readup.org.cer
COPY ssl/dev.readup.org.key /etc/ssl/dev.readup.org.key

# ── nginx config (adapted for in-container localhost proxying) ────────────────
COPY unified-dev-env/nginx.conf /etc/nginx/nginx.conf

# ── Node.js 22 via nvm ────────────────────────────────────────────────────────
USER dev
WORKDIR /home/dev

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
	&& . "$NVM_DIR/nvm.sh" \
	&& nvm install 22 \
	&& nvm alias default 22 \
	&& echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc \
	&& echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.bashrc \
	&& echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ~/.bashrc

# ── Claude Code ───────────────────────────────────────────────────────────────
RUN . "$NVM_DIR/nvm.sh" && npm install -g @anthropic-ai/claude-code

# ── VS Code Server & extensions ───────────────────────────────────────────────
# Deliberately NOT installed here. The VS Code Dev Containers extension installs
# the matching VS Code Server on first attach, and the extensions listed under
# customizations.vscode.extensions in .devcontainer/devcontainer.json:
#   ms-dotnettools.vscode-dotnet-runtime  — .NET runtime acquisition (dep)
#   ms-dotnettools.csharp                 — C# language support (Roslyn/OmniSharp)
#   ms-dotnettools.csdevkit               — C# Dev Kit (enhanced tooling)
#   biomejs.biome                         — Biome formatter/linter
# The install is cached in an anonymous volume on ~/.vscode-server (docker-compose.yml)
# so it survives container recreation and only downloads once.
#
# Create the directory dev-owned so Docker initializes the anonymous volume with
# dev:dev ownership. Otherwise Docker creates the (empty) volume as root:root and
# the dev user can't write the VS Code Server into it (mkdir: Permission denied).
RUN mkdir -p /home/dev/.vscode-server

# ── Symlink node/npm/npx/claude into system PATH (for root and non-login shells) ──
USER root
RUN NODE_BIN_DIR="$(ls -d /home/dev/.nvm/versions/node/v22.*/bin 2>/dev/null | head -1)" \
	&& ln -sf "$NODE_BIN_DIR/node"   /usr/local/bin/node \
	&& ln -sf "$NODE_BIN_DIR/npm"    /usr/local/bin/npm \
	&& ln -sf "$NODE_BIN_DIR/npx"    /usr/local/bin/npx \
	&& ln -sf "$NODE_BIN_DIR/claude" /usr/local/bin/claude

# ── Bootstrap script and default repo config ──────────────────────────────────
COPY --chown=dev:dev unified-dev-env/bootstrap-repos.sh    /home/dev/bootstrap-repos.sh
COPY --chown=dev:dev unified-dev-env/repos.conf            /home/dev/repos.conf
COPY --chown=dev:dev unified-dev-env/start.sh              /home/dev/start.sh
COPY --chown=dev:dev unified-dev-env/swap-api-target.sh    /home/dev/swap-api-target.sh
COPY --chown=dev:dev unified-dev-env/dev-layout.kdl        /home/dev/dev-layout.kdl
COPY --chown=dev:dev unified-dev-env/CLAUDE.md             /home/dev/CLAUDE.md
RUN chmod +x /home/dev/bootstrap-repos.sh /home/dev/start.sh /home/dev/swap-api-target.sh

COPY unified-dev-env/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 443  — nginx HTTPS (Readup dev services)
# 5432 — PostgreSQL (optional; expose if you need external DB access)
EXPOSE 443 5432

ENTRYPOINT ["/entrypoint.sh"]
