# Readup Unified Development Environment
#
# A single Ubuntu 24.04 container containing all services needed for local Readup
# development: PostgreSQL 14, .NET 10, Node 22, nginx (SSL proxy), PowerShell,
# and Claude Code.
#
# VS Code access: use the VS Code Remote SSH extension to connect. The VS Code Server
# binary and a set of useful extensions are pre-installed during the build so the
# first connection is fast.
#
# Build context must be the dev-env repo root so the SSL certs can be copied in:
#
#   docker build -f unified-dev-env/Dockerfile -t readup-dev .
#
# Run example (persist DB data and SSH keys):
#
#   docker run -d --name readup-dev \
#     -p 2222:22 \
#     -p 443:443 \
#     -v readup-db-data:/var/lib/postgresql/14/main \
#     -v ~/.ssh/readup-deploy:/home/dev/.ssh/id_ed25519:ro \
#     readup-dev
#
# Connect from VS Code via Remote SSH:  ssh dev@localhost -p 2222  (password: dev)
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
	tmux \
	build-essential \
	ca-certificates \
	gnupg \
	lsb-release \
	sudo \
	unzip \
	jq \
	openssh-server \
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

# ── dev user ──────────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash dev \
	&& echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
	# Default password — only used for VS Code Remote SSH from localhost.
	# Change or disable once you configure key-based auth.
	&& echo "dev:dev" | chpasswd \
	# Allow nginx (www-data) to traverse /home/dev to serve static files.
	# useradd creates home dirs as 750; www-data needs the world-execute bit.
	&& chmod o+x /home/dev

# ── SSH server ────────────────────────────────────────────────────────────────
RUN sed -i \
	-e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
	-e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
	/etc/ssh/sshd_config \
	&& ssh-keygen -A \
	&& mkdir -p /run/sshd /var/log/postgresql

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

# ── VS Code Server (pre-installed for fast first connection) ──────────────────
# Downloads the latest stable VS Code Server. If the connecting VS Code client
# matches this build's commit, it skips the download entirely ("Reusing existing
# installation"). If the client is newer, VS Code downloads its own matching
# version into a separate commit directory — connection still works either way.
RUN ARCH=$(uname -m) \
	&& case "$ARCH" in \
	x86_64)  VSCODE_ARCH="x64"   ;; \
	aarch64) VSCODE_ARCH="arm64" ;; \
	*) echo "Unsupported arch: $ARCH" && exit 1 ;; \
	esac \
	&& curl -sL \
	"https://update.code.visualstudio.com/latest/server-linux-${VSCODE_ARCH}/stable" \
	-o /tmp/vscode-server.tar.gz \
	&& tar -xz -C /tmp/ -f /tmp/vscode-server.tar.gz \
	&& COMMIT=$(jq -r '.commit' /tmp/vscode-server-linux-*/product.json) \
	&& echo "VS Code Server commit: $COMMIT" \
	&& DEST="$HOME/.vscode-server/bin/$COMMIT" \
	&& mkdir -p "$DEST" \
	&& mv /tmp/vscode-server-linux-*/* "$DEST/" \
	# Sentinel file: tells VS Code Remote SSH the install is complete.
	&& touch "$DEST/0" \
	&& rm /tmp/vscode-server.tar.gz

# ── VS Code Server extensions ─────────────────────────────────────────────────
# Pre-populated into ~/.vscode-server/extensions/ so they are available on
# first connection without needing to download.
#
# Extensions installed:
#   ms-dotnettools.vscode-dotnet-runtime  — .NET runtime acquisition (dep)
#   ms-dotnettools.csharp                 — C# language support (Roslyn/OmniSharp)
#   ms-dotnettools.csdevkit               — C# Dev Kit (enhanced tooling)
#   biomejs.biome                         — Biome formatter/linter
#
# NOTE: ms-dotnettools.csdevkit is free for personal/open-source use but
# requires a Microsoft account for commercial use.
#
# All four extensions ship native binaries and have platform-specific VSIX
# packages on the marketplace. We detect the arch and request the matching
# platform variant so arm64 and amd64 both get the correct binaries.
# filterType 7 = extension ID,  filterType 23 = target platform.
RUN ARCH=$(uname -m) \
	&& case "$ARCH" in \
	x86_64)  VSCODE_PLATFORM="linux-x64"   ;; \
	aarch64) VSCODE_PLATFORM="linux-arm64" ;; \
	*) echo "Unsupported arch: $ARCH" && exit 1 ;; \
	esac \
	&& for EXT_ID in \
	ms-dotnettools.vscode-dotnet-runtime \
	ms-dotnettools.csharp \
	ms-dotnettools.csdevkit \
	biomejs.biome ; \
	do \
	PUBLISHER="${EXT_ID%%.*}" ; \
	NAME="${EXT_ID#*.}" ; \
	VERSION=$(curl -s -X POST \
	"https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery?api-version=7.2-preview.1" \
	-H "Content-Type: application/json" \
	-H "Accept: application/json;api-version=7.2-preview.1" \
	-d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${EXT_ID}\"},{\"filterType\":23,\"value\":\"${VSCODE_PLATFORM}\"}]}],\"flags\":529}" \
	| jq -r '.results[0].extensions[0].versions[0].version') ; \
	echo "Installing extension: $EXT_ID v$VERSION ($VSCODE_PLATFORM)" ; \
	DEST="$HOME/.vscode-server/extensions/${PUBLISHER}.${NAME}-${VERSION}" ; \
	mkdir -p "$DEST" ; \
	curl -sL \
	"https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${PUBLISHER}/vsextensions/${NAME}/${VERSION}/vspackage?targetPlatform=${VSCODE_PLATFORM}" \
	-o /tmp/ext.vsix ; \
	unzip -q /tmp/ext.vsix "extension/*" -d /tmp/ext_tmp ; \
	cp -r /tmp/ext_tmp/extension/. "$DEST/" ; \
	rm -rf /tmp/ext.vsix /tmp/ext_tmp ; \
	done

# ── Symlink node/npm/npx/claude into system PATH (for root and non-login shells) ──
USER root
RUN NODE_BIN_DIR="$(ls -d /home/dev/.nvm/versions/node/v22.*/bin 2>/dev/null | head -1)" \
	&& ln -sf "$NODE_BIN_DIR/node"   /usr/local/bin/node \
	&& ln -sf "$NODE_BIN_DIR/npm"    /usr/local/bin/npm \
	&& ln -sf "$NODE_BIN_DIR/npx"    /usr/local/bin/npx \
	&& ln -sf "$NODE_BIN_DIR/claude" /usr/local/bin/claude

# ── Bootstrap script and default repo config ──────────────────────────────────
COPY --chown=dev:dev unified-dev-env/bootstrap-repos.sh /home/dev/bootstrap-repos.sh
COPY --chown=dev:dev unified-dev-env/repos.conf         /home/dev/repos.conf
COPY --chown=dev:dev unified-dev-env/start.sh           /home/dev/start.sh
COPY --chown=dev:dev unified-dev-env/CLAUDE.md          /home/dev/CLAUDE.md
RUN chmod +x /home/dev/bootstrap-repos.sh /home/dev/start.sh

COPY unified-dev-env/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 22   — SSH  (VS Code Remote SSH)
# 443  — nginx HTTPS (Readup dev services)
# 5432 — PostgreSQL (optional; expose if you need external DB access)
EXPOSE 22 443 5432

ENTRYPOINT ["/entrypoint.sh"]
