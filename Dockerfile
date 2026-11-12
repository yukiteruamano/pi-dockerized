# syntax=docker/dockerfile:1

# Use Debian slim as lightweight Linux base, pinned by digest so a rebuild gets
# the same bytes (Renovate bumps tag + digest together). The Docker CLI, when
# installed, talks to the host's Docker daemon via the opt-in mounted socket.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

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
ARG PNPM_VERSION=12.16.1
# uv release; override with --build-arg UV_VERSION=x.y.z
ARG UV_VERSION=0.13.6
# Node.js major installed through nvm (Pi requires >= 22.19). The minor/patch
# floats inside the major so security fixes are picked up on rebuild.
ARG NODE_VERSION=24
# Pi CLI release; override with --build-arg PI_VERSION=x.y.z
ARG PI_VERSION=v1.5.2
# qmd (on-device markdown search) release
# renovate: datasource=npm depName=@tobilu/qmd
ARG QMD_VERSION=2.8.3
# sha256 of each installer script, checked before it runs. The nvm and uv URLs
# are versioned, so these only change with NVM_VERSION / UV_VERSION (override
# both together). The pnpm installer is not versioned upstream: if it changes
# the build stops here so the new script can be reviewed.
ARG NVM_INSTALL_SHA256=48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e
ARG UV_INSTALL_SHA256=f7a56e7afaec49a3bcbc3ac3cdbe917e7c6ce30e0d815308a12e531aa5ef23b7
ARG PNPM_INSTALL_SHA256=53d3ad6ef67d49d6951f3326bd3180e5c504c8f695bcdf73bb61ec7a4d4c9407
# yt-dlp release (PyPI). Pinned so a rebuild never pulls an unreviewed release;
# Renovate bumps it, which also keeps the extractors fresh.
# renovate: datasource=pypi depName=yt-dlp
ARG YT_DLP_VERSION=2026.10.26
# Fingerprint of the Docker apt repository's signing key (primary key). The key
# is downloaded over TLS and only trusted when it matches.
ARG DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# pnpm refuses to resolve any package (including the transitive dependencies of
# Pi and qmd, which have no lockfile here) published less than this many minutes
# ago: a freshly hijacked release has time to be caught and yanked first. The
# pinned top-level releases must be at least this old too (Renovate waits longer;
# see renovate.json). Exposed to the RUN steps only, not to the running image.
ARG PNPM_CONFIG_MINIMUM_RELEASE_AGE=1440
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
    ffmpeg \
    python3 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI only (uses host Docker daemon via mounted socket), and only
# when INSTALL_DOCKER_CLI=true: without the socket it is dead weight and extra
# attack surface. We don't need docker-ce (daemon) or containerd.io.
# The repository key must be exactly one primary key with the pinned fingerprint.
RUN if [ "$INSTALL_DOCKER_CLI" = true ]; then \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.asc && \
      gpg --show-keys --with-colons /tmp/docker.asc > /tmp/docker.keys && \
      test "$(awk -F: '$1 == "pub"' /tmp/docker.keys | wc -l)" -eq 1 && \
      test "$(awk -F: '$1 == "fpr" { print $10; exit }' /tmp/docker.keys)" = "$DOCKER_GPG_FINGERPRINT" && \
      install -m 0644 /tmp/docker.asc /etc/apt/keyrings/docker.asc && \
      rm -f /tmp/docker.asc /tmp/docker.keys && \
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

# Keep each global install in its own virtual store. From 12.16.0 pnpm links
# every global package (and pnpm itself, installed by `pnpm setup` below) from a
# shared virtual store inside the content-addressable store
# ($PNPM_HOME/store/v11/links). The store is a BuildKit cache mount in the two
# install layers below, so those links would point at a path that never reaches
# the image: `$PNPM_HOME/bin/pnpm` is a shim that execs the link and dies with
# "not found", and a global package would be a dangling link at run time. With
# `project` the files stay under $PNPM_HOME/global, which is committed; the
# cache mount keeps serving the downloads.
# https://github.com/pnpm/pnpm/releases/tag/v12.16.0 ("Adding packages and global
# packages" section)
ENV PNPM_CONFIG_VIRTUAL_STORE_TYPE="project"

# The installer checks the pnpm tarball against npm's registry signature with a
# key pinned inside the script, but silently drops to a checksum-only check when
# openssl is missing: require it (ca-certificates ships it) so that never happens.
# The uv installer likewise carries the per-platform sha256 of its binaries.
RUN command -v openssl >/dev/null && \
    curl -fsSLo /tmp/pnpm-install.sh https://get.pnpm.io/install.sh && \
    echo "${PNPM_INSTALL_SHA256}  /tmp/pnpm-install.sh" | sha256sum -c - && \
    env PNPM_VERSION="${PNPM_VERSION}" ENV="$HOME/.bashrc" SHELL="$(which bash)" sh /tmp/pnpm-install.sh && \
    rm -f /tmp/pnpm-install.sh && \
    mkdir -p "$PNPM_HOME/store" && \
    "$PNPM_HOME/bin/pnpm" --version

# Add pnpm, nvm, node, uv and ~/.local/bin to PATH
# Node.js is available via the NVM default symlink created above.
# ~/.local/bin holds user-installed CLIs (uv tools, pipx apps).
ENV PATH="$PNPM_HOME/bin:$NVM_DIR/default:/home/coder/.local/bin:$PATH"

# Install yt-dlp (YouTube stream URLs for pi-web-access frame extraction) as an
# isolated tool via uv (upstream ships it on PyPI; distro packages lag behind
# extractor fixes). Pinned by YT_DLP_VERSION (Renovate keeps it current).
RUN uv tool install "yt-dlp==${YT_DLP_VERSION}" && yt-dlp --version

# NVM installs the current Node LTS and the Docker apt repo tracks `stable` on
# purpose: both follow upstream security fixes. Pi, qmd, yt-dlp, uv, pnpm and
# nvm are pinned; the npm dependencies of Pi and qmd are resolved at build time
# under PNPM_CONFIG_MINIMUM_RELEASE_AGE. Fail the build if pnpm stops reading
# that variable: the release-age gate would otherwise turn off silently.
RUN test "$(pnpm config get minimum-release-age)" = "${PNPM_CONFIG_MINIMUM_RELEASE_AGE}"

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
# ARG PI_VERSION pins the release (default v1.5.2).
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
# Pi loads extensions (the guard's index.ts included) through jiti, whose
# on-disk transpile cache lives in the session-writable $TMPDIR: a forged entry
# would replace the guard's code on /reload. Transpile in memory only.
ENV JITI_FS_CACHE=false
# Do NOT set PI_PACKAGE_DIR: Pi reads its own package.json (version), themes and
# docs from it, so overriding it makes `pi --version` report 0.0.0.

# Seed the baked settings (security defaults) and the guard. Pi Packages are NOT
# installed here: `pi-dockerized extensions install` runs the official
# `pi install` in a throwaway container against a host directory (ext-agent/),
# which sessions mount read-only over the agent's settings.json, npm/ and git/.
# Installing at build time meant re-fetching them on every rebuild.
#
# Ownership is what makes the baked resources immutable, not just missing write
# bits: the session runs as the host uid (often 1000, i.e. `coder` itself) and
# joins the `coder` group, and an owner can always chmod its files back. So the
# guard, settings.json, AGENTS.md, mcp.json, skills/, prompts/ and themes/ are
# root-owned and read-only, and so is every directory above them
# (/home/coder, ~/.pi, ~/.pi/agent): those are root:coder 1775, where the
# session may still create the entries Pi and its tools need (a tool cache,
# lock files, dotfiles in $HOME) but, with the sticky bit, cannot rename or
# delete a root-owned entry such as extensions/ or AGENTS.md. Only the runtime
# state (sessions/, auth.json, mcp-auth.json, trust.json, mcp.log, ~/.npm,
# ~/.cache) stays coder-owned and group-writable; the wrapper bind-mounts it from
# the host, and keeping it writable means Pi still starts if a mount is missing.
# entrypoint.sh refuses to start when this lock does not hold (lock-check.sh).
USER root
COPY --chown=root:root container/settings.base.json /home/coder/.pi/agent/settings.json
COPY --chown=root:root container/AGENTS.md /home/coder/.pi/agent/AGENTS.md
COPY --chown=root:root extensions/pi-security-guard /home/coder/.pi/agent/extensions/pi-security-guard
COPY --chown=root:root \
     policies/unsafe-tool-patterns.json \
     policies/prompt-injection-patterns.json \
     policies/allow-patterns.json \
     policies/VERSION \
     /home/coder/.pi/agent/extensions/pi-security-guard/policies/
# Diagnostics run by `pi-dockerized doctor` / `auth`, the `pi install` wrapper
# and settings guard used by `pi-dockerized extensions`, the lock check run by
# the entrypoint, and a reference copy of the baked settings (the agent's own
# settings.json can be shadowed by the host's ext-agent one): root-owned in
# root-owned /usr/local, so the session cannot edit them (the executable bit of
# the scripts is set in git).
COPY container/doctor.sh container/auth-check.sh container/ext-install.sh container/ext-agent.mjs container/lock-check.sh /usr/local/lib/pi-dockerized/
COPY container/settings.base.json /usr/local/lib/pi-dockerized/settings.base.json
RUN agent=/home/coder/.pi/agent && \
    mkdir -p "$agent/skills" "$agent/prompts" "$agent/themes" "$agent/sessions" \
      /home/coder/.cache/qmd /home/coder/.npm && \
    printf '{\n  "mcpServers": {}\n}\n' > "$agent/mcp.json" && \
    printf '{}\n' > "$agent/auth.json" && \
    printf '{}\n' > "$agent/mcp-auth.json" && \
    printf '{}\n' > "$agent/trust.json" && \
    : > "$agent/mcp.log" && \
    chown -R root:root "$agent" && \
    chmod -R a-w "$agent/extensions" "$agent/skills" "$agent/prompts" "$agent/themes" \
      "$agent/settings.json" "$agent/AGENTS.md" "$agent/mcp.json" && \
    chown -R coder:coder "$agent/sessions" "$agent/auth.json" "$agent/mcp-auth.json" \
      "$agent/trust.json" "$agent/mcp.log" /home/coder/.npm /home/coder/.cache && \
    chmod -R g+rwX "$agent/sessions" "$agent/auth.json" "$agent/mcp-auth.json" \
      "$agent/trust.json" "$agent/mcp.log" /home/coder/.npm /home/coder/.cache && \
    chown root:coder /home/coder /home/coder/.pi "$agent" && \
    chmod 1775 /home/coder /home/coder/.pi "$agent" && \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + && \
    test -z "$(find / -xdev -perm /6000 -type f -print -quit)"
# No setuid/setgid binaries are left (su, mount, passwd, ssh-keysign, ...): the
# guard's root ownership then does not depend on no-new-privileges alone.
USER coder
# Fail the build, not the first session, when the lock does not hold for the
# image's own user (uid 1000, the common host uid).
RUN /usr/local/lib/pi-dockerized/lock-check.sh

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
