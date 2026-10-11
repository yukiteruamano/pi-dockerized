# syntax=docker/dockerfile:1

# Use Debian slim as lightweight Linux base, pinned by digest so a rebuild gets
# the same bytes (Renovate bumps tag + digest together). The Docker CLI, when
# installed, talks to the host's Docker daemon via the opt-in mounted socket.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# Fail fast inside RUN pipelines (curl | sh, | tee, …)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Parameterize tool versions for easier updates
# Pin releases for reproducible builds; override with --build-arg.
# PI_VERSION pins the Pi CLI release (update with --build-arg PI_BUILD_TIME to
# bust the pnpm cache; see `update`). Avoid `latest` in production builds: a
# moving tag breaks reproducibility and widens supply-chain exposure.
# NVM_VERSION and UV_VERSION are checksum-pinned below: bump them by hand,
# together with their *_INSTALL_SHA256 (Renovate does not manage them).
ARG NVM_VERSION=v0.40.8
# renovate: datasource=npm depName=pnpm
ARG PNPM_VERSION=12.11.2
# uv release; override with --build-arg UV_VERSION=x.y.z
ARG UV_VERSION=0.13.0
# Node.js major installed through nvm (Pi requires >= 22.19). The minor/patch
# floats inside the major so security fixes are picked up on rebuild.
ARG NODE_VERSION=24
# Pi CLI release; override with --build-arg PI_VERSION=x.y.z
ARG PI_VERSION=v1.1.0
# qmd (on-device markdown search) release
# renovate: datasource=npm depName=@tobilu/qmd
ARG QMD_VERSION=2.8.3
# sha256 of each installer script, checked before it runs. The nvm and uv URLs
# are versioned, so these only change with NVM_VERSION / UV_VERSION (override
# both together). The pnpm installer is not versioned upstream: if it changes
# the build stops here so the new script can be reviewed.
ARG NVM_INSTALL_SHA256=48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e
ARG UV_INSTALL_SHA256=283cbef4bdaca819bd896b0dacb8a085c4c05dbc880642aa5001d97bc4db74ba
ARG PNPM_INSTALL_SHA256=a5cb30faa96ded2937d60f80041e9d47b5280b224fbdcd9d3b136000a8edabf8
# The Docker CLI is only useful with the host socket mounted (setting.docker_socket).
# `pi-dockerized build` sets this from that setting.
ARG INSTALL_DOCKER_CLI=true

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

# Install Docker CLI only (uses host Docker daemon via mounted socket), and only
# when INSTALL_DOCKER_CLI=true: without the socket it is dead weight and extra
# attack surface. We don't need docker-ce (daemon) or containerd.io.
RUN if [ "$INSTALL_DOCKER_CLI" = true ]; then \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
      chmod a+r /etc/apt/keyrings/docker.asc && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null && \
      apt-get update && \
      apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
      rm -rf /var/lib/apt/lists/*; \
    fi

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
RUN curl -fsSLo /tmp/nvm-install.sh "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" && \
    echo "${NVM_INSTALL_SHA256}  /tmp/nvm-install.sh" | sha256sum -c - && \
    bash /tmp/nvm-install.sh && \
    rm -f /tmp/nvm-install.sh && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install uv (Python package manager) as coder user
# See: https://docs.astral.sh/uv/getting-started/installation/
RUN curl -fsSLo /tmp/uv-install.sh "https://astral.sh/uv/${UV_VERSION}/install.sh" && \
    echo "${UV_INSTALL_SHA256}  /tmp/uv-install.sh" | sha256sum -c - && \
    sh /tmp/uv-install.sh && \
    rm -f /tmp/uv-install.sh

# Install pnpm via the official standalone installer (native binary, no Node needed)
# The script installs to $PNPM_HOME (default: ~/.local/share/pnpm) and appends a
# PATH snippet to ~/.bashrc; we wire PATH via ENV below so it works non-interactively.
# PNPM_VERSION pins the installed release (override with --build-arg PNPM_VERSION=x.y.z).
# SHELL/ENV must be set explicitly in Docker builds (documented by pnpm.io) because
# the installer cannot infer the shell and otherwise fails with ERR_PNPM_UNKNOWN_SHELL.
# See: https://pnpm.io/installation (sections "POSIX systems", "In a Docker container",
# "Installing a specific version")
ENV PNPM_HOME="/home/coder/.local/share/pnpm"
RUN curl -fsSLo /tmp/pnpm-install.sh https://get.pnpm.io/install.sh && \
    echo "${PNPM_INSTALL_SHA256}  /tmp/pnpm-install.sh" | sha256sum -c - && \
    env PNPM_VERSION="${PNPM_VERSION}" ENV="$HOME/.bashrc" SHELL="$(which bash)" sh /tmp/pnpm-install.sh && \
    rm -f /tmp/pnpm-install.sh && \
    mkdir -p "$PNPM_HOME/store" && \
    "$PNPM_HOME/bin/pnpm" --version

# Add pnpm, nvm, node, uv and ~/.local/bin to PATH
# Node.js is available via the NVM default symlink created above.
# ~/.local/bin holds user-installed CLIs (uv tools, pipx apps).
ENV PATH="$PNPM_HOME/bin:$NVM_DIR/default:/home/coder/.local/bin:$PATH"

# NVM installs the current Node LTS and the Docker apt repo tracks `stable` on
# purpose: both follow upstream security fixes. Pi, uv, pnpm and nvm are pinned.

# Install qmd (on-device markdown search engine) globally with pnpm. pnpm skips
# dependency install scripts unless allowed; these are the native modules qmd
# itself declares in its onlyBuiltDependencies. Its index and downloaded models
# live in ~/.cache/qmd, which the wrapper persists on the host.
# The pnpm store is a BuildKit cache mount, so rebuilds do not re-download.
RUN --mount=type=cache,target=/home/coder/.local/share/pnpm/store,uid=1000,gid=1000 \
    pnpm add -g @tobilu/qmd@"${QMD_VERSION}" \
      --allow-build=better-sqlite3 --allow-build=esbuild --allow-build=node-llama-cpp \
      --allow-build=tree-sitter-go --allow-build=tree-sitter-python \
      --allow-build=tree-sitter-rust --allow-build=tree-sitter-typescript

# Install the Pi coding agent CLI globally with pnpm.
# ARG PI_BUILD_TIME is only passed during 'update' to bust cache.
# ARG PI_VERSION pins the release (default v1.1.0).
ARG PI_BUILD_TIME=0
RUN --mount=type=cache,target=/home/coder/.local/share/pnpm/store,uid=1000,gid=1000 \
    pnpm add -g @earendil-works/pi-coding-agent@"${PI_VERSION}" --allow-build=@earendil-works/pi-coding-agent && pi --version
# Guard: Pi reports 0.0.0 when it cannot find its own package.json (e.g. when
# PI_PACKAGE_DIR is overridden). Fail the build instead of shipping that image.
RUN test "$(pi --version 2>&1 | tail -n 1)" != "0.0.0"

# Pi's agent directory. Extensions, settings, AGENTS.md, prompts and themes are
# baked here read-only at build time; the writable state (sessions,
# auth, MCP OAuth, trust, logs) is bind-mounted from the host at run time.
ENV PI_CODING_AGENT_DIR="/home/coder/.pi/agent"
# Do NOT set PI_PACKAGE_DIR: Pi reads its own package.json (version), themes and
# docs from it, so overriding it makes `pi --version` report 0.0.0.
RUN mkdir -p /home/coder/.pi/agent/extensions \
    /home/coder/.pi/agent/skills \
    /home/coder/.pi/agent/prompts \
    /home/coder/.pi/agent/themes \
    /home/coder/.pi/agent/sessions \
    /home/coder/.cache/qmd \
    /home/coder/.npm && \
    printf '{\n  "mcpServers": {}\n}\n' > /home/coder/.pi/agent/mcp.json && \
    printf '{}\n' > /home/coder/.pi/agent/auth.json && \
    printf '{}\n' > /home/coder/.pi/agent/mcp-auth.json && \
    printf '{}\n' > /home/coder/.pi/agent/trust.json && \
    : > /home/coder/.pi/agent/mcp.log

# Seed the baked settings (security defaults) and the guard. Pi Packages are NOT
# installed here: `pi-dockerized extensions install` runs the official
# `pi install` in a throwaway container against a host directory (ext-agent/),
# which sessions mount read-only over the agent's settings.json, npm/ and git/.
# Installing at build time meant re-fetching them on every rebuild.
# COPY creates root-owned files regardless of USER, so this block runs as root
# and fixes ownership; the lock step below runs as coder again.
USER root
COPY container/settings.base.json /home/coder/.pi/agent/settings.json
COPY container/AGENTS.md /home/coder/.pi/agent/AGENTS.md
COPY extensions/pi-security-guard /home/coder/.pi/agent/extensions/pi-security-guard
COPY policies/unsafe-tool-patterns.json \
     policies/prompt-injection-patterns.json \
     policies/allow-patterns.json \
     policies/VERSION \
     /home/coder/.pi/agent/extensions/pi-security-guard/policies/
# Diagnostics run by `pi-dockerized doctor` / `auth`, the `pi install` wrapper
# and settings guard used by `pi-dockerized extensions`, and a reference copy of
# the baked settings (the agent's own settings.json can be shadowed by the host's
# ext-agent one): root-owned, so the session cannot edit them (the executable
# bit of the scripts is set in git).
COPY container/doctor.sh container/auth-check.sh container/ext-install.sh container/ext-agent.mjs /usr/local/lib/pi-dockerized/
COPY container/settings.base.json /usr/local/lib/pi-dockerized/settings.base.json
RUN chown -R coder:coder /home/coder/.pi /home/coder/.npm /home/coder/.cache && \
    chmod -R g+rwX /home/coder/.pi /home/coder/.npm /home/coder/.cache
USER coder

# Lock the baked *resources* read-only. The runtime user joins the image's
# `coder` group (via --group-add), so removing write bits makes extensions,
# settings, AGENTS.md, prompts, themes and the package store immutable to the
# agent. The writable state (sessions/, auth.json, mcp-auth.json,
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

# Image metadata: `pi-dockerized` compares the version label with the wrapper's
# to notice a stale image, and the docker-cli label to notice a missing CLI.
# These two ARGs change on every release/commit, so they are declared last to
# keep them from invalidating the cache of every layer above.
ARG WRAPPER_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="pi-dockerized" \
      org.opencontainers.image.description="Sandboxed container for the Pi coding agent" \
      org.opencontainers.image.source="https://github.com/yukiteruamano/pi-dockerized" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      pi-dockerized.docker-cli="${INSTALL_DOCKER_CLI}"

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
