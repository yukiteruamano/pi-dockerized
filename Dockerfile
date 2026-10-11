# Use Debian slim as lightweight Linux base
# Note: We only install Docker CLI to use host's Docker daemon via mounted socket
FROM debian:trixie-slim

# Fail fast inside RUN pipelines (curl | sh, | tee, …)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Parameterize tool versions for easier updates
# Pin releases for reproducible builds; override with --build-arg.
# PI_VERSION pins the Pi CLI release (update with --build-arg PI_BUILD_TIME to
# bust the pnpm cache; see `update`). Avoid `latest` in production builds: a
# moving tag breaks reproducibility and widens supply-chain exposure.
ARG NVM_VERSION=v0.40.8
ARG PNPM_VERSION=12.10.1
# uv release; override with --build-arg UV_VERSION=x.y.z
ARG UV_VERSION=0.13.0
# Pi CLI release; override with --build-arg PI_VERSION=x.y.z
ARG PI_VERSION=v1.1.0

# Install base dependencies and useful CLI tools for coding agents
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    ca-certificates \
    zip \
    unzip \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI only (uses host Docker daemon via mounted socket)
# We don't need docker-ce (daemon) or containerd.io since we use the host's Docker
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
# Note: Docker socket group membership is granted at run time by the wrapper
# (config-lib.sh) with `--group-add <socket GID>`; the entrypoint never runs as
# root and does not edit /etc/group.
# There is intentionally no sudo: the agent must never gain root, so neither a
# sudoers entry nor the sudo binary (a setuid-root vector) is installed.
RUN useradd -m -s /bin/bash -u 1000 coder

# Install NVM and Node.js LTS as coder user (Pi requires Node.js >= 22.19)
USER coder
WORKDIR /home/coder
ENV NVM_DIR="/home/coder/.nvm"
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install --lts && \
    nvm alias default node && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install uv (Python package manager) as coder user
# See: https://docs.astral.sh/uv/getting-started/installation/
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh

# Install pnpm via the official standalone installer (native binary, no Node needed)
# The script installs to $PNPM_HOME (default: ~/.local/share/pnpm) and appends a
# PATH snippet to ~/.bashrc; we wire PATH via ENV below so it works non-interactively.
# PNPM_VERSION pins the installed release (override with --build-arg PNPM_VERSION=x.y.z).
# SHELL/ENV must be set explicitly in Docker builds (documented by pnpm.io) because
# the installer cannot infer the shell and otherwise fails with ERR_PNPM_UNKNOWN_SHELL.
# See: https://pnpm.io/installation (sections "POSIX systems", "In a Docker container",
# "Installing a specific version")
ENV PNPM_HOME="/home/coder/.local/share/pnpm"
RUN curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION="${PNPM_VERSION}" ENV="$HOME/.bashrc" SHELL="$(which bash)" sh - && "$PNPM_HOME/bin/pnpm" --version

# Add pnpm, nvm, node, uv and ~/.local/bin to PATH
# Node.js is available via the NVM default symlink created above.
# ~/.local/bin holds user-installed CLIs (uv tools, pipx apps).
ENV PATH="$PNPM_HOME/bin:$NVM_DIR/default:/home/coder/.local/bin:$PATH"

# NVM installs the current Node LTS and the Docker apt repo tracks `stable` on
# purpose: both follow upstream security fixes. Pi, uv, pnpm and nvm are pinned.

# Install the Pi coding agent CLI globally with pnpm.
# ARG PI_BUILD_TIME is only passed during 'update' to bust cache.
# ARG PI_VERSION pins the release (default v1.1.0).
ARG PI_BUILD_TIME=0
RUN pnpm add -g @earendil-works/pi-coding-agent@"${PI_VERSION}" --allow-build=@earendil-works/pi-coding-agent && pi --version
# Guard: Pi reports 0.0.0 when it cannot find its own package.json (e.g. when
# PI_PACKAGE_DIR is overridden). Fail the build instead of shipping that image.
RUN test "$(pi --version 2>&1 | tail -n 1)" != "0.0.0"

# Pi's agent directory. Extensions, settings, AGENTS.md, prompts and themes are
# baked here read-only at build time; the writable state (skills, sessions,
# auth, MCP OAuth, trust, logs) is bind-mounted from the host at run time.
ENV PI_CODING_AGENT_DIR="/home/coder/.pi/agent"
# Do NOT set PI_PACKAGE_DIR: Pi reads its own package.json (version), themes and
# docs from it, so overriding it makes `pi --version` report 0.0.0.
RUN mkdir -p /home/coder/.pi/agent/extensions \
    /home/coder/.pi/agent/skills \
    /home/coder/.pi/agent/prompts \
    /home/coder/.pi/agent/themes \
    /home/coder/.pi/agent/sessions \
    /home/coder/.npm && \
    printf '{\n  "mcpServers": {}\n}\n' > /home/coder/.pi/agent/mcp.json && \
    printf '{}\n' > /home/coder/.pi/agent/auth.json && \
    printf '{}\n' > /home/coder/.pi/agent/mcp-auth.json && \
    printf '{}\n' > /home/coder/.pi/agent/trust.json && \
    : > /home/coder/.pi/agent/mcp.log

# Seed the baked settings (security defaults) and the guard before installing
# extensions (so `pi install` appends its package declarations to settings.json).
# COPY creates root-owned files regardless of USER, so this block runs as root
# and fixes ownership; the install/lock steps below run as coder again.
USER root
COPY container/settings.base.json /home/coder/.pi/agent/settings.json
COPY container/AGENTS.md /home/coder/.pi/agent/AGENTS.md
COPY extensions/pi-security-guard /home/coder/.pi/agent/extensions/pi-security-guard
COPY policies/unsafe-tool-patterns.json \
     policies/prompt-injection-patterns.json \
     policies/allow-patterns.json \
     /home/coder/.pi/agent/extensions/pi-security-guard/policies/
COPY install-extensions /tmp/install-extensions
RUN chown -R coder:coder /home/coder/.pi /home/coder/.npm && \
    chmod -R g+rwX /home/coder/.pi /home/coder/.npm
USER coder

# Install the extensions/packages listed in install-extensions. pi install
# writes the declarations to settings.json and fetches the packages. `pi list`
# fails the build if a package did not reconcile.
RUN set -euo pipefail; \
    . "$NVM_DIR/nvm.sh"; \
    if grep -qvE '^[[:space:]]*(#|$)' /tmp/install-extensions; then \
      grep -vE '^[[:space:]]*(#|$)' /tmp/install-extensions | while IFS= read -r src; do \
        echo "Installing Pi extension: $src"; \
        pi install "$src"; \
      done; \
    else \
      echo "install-extensions: no packages listed (only the built-in guard)"; \
    fi; \
    pi list

# Lock the baked *resources* read-only. The runtime user joins the image's
# `coder` group (via --group-add), so removing write bits makes extensions,
# settings, AGENTS.md, prompts, themes and the package store immutable to the
# agent. The writable state (skills/, sessions/, auth.json, mcp-auth.json,
# trust.json, mcp.log) is intentionally left writable in the image and is
# bind-mounted read-write from the host at run time; keeping it writable also
# means Pi still starts if a state mount is ever missing.
# Root is needed to strip write bits from the root-owned COPY results.
USER root
RUN chmod -R a-w \
      /home/coder/.pi/agent/extensions \
      /home/coder/.pi/agent/prompts \
      /home/coder/.pi/agent/themes && \
    chmod a-w \
      /home/coder/.pi/agent/settings.json \
      /home/coder/.pi/agent/AGENTS.md \
      /home/coder/.pi/agent/mcp.json
USER coder

# Default working directory; entrypoint.sh cd's into the project (PI_WORKDIR,
# falling back to the Docker --workdir set by the wrapper).
WORKDIR /

# Copy entrypoint script. COPY is not subject to USER (files are created
# root-owned) and preserves the source mode, and entrypoint.sh is committed as
# 0755, so no root step and no chmod are required. The script stays root-owned
# in root-owned /usr/local/bin, so the runtime user cannot modify it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# entrypoint.sh performs no privilege changes.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command is to run pi
CMD ["pi"]
