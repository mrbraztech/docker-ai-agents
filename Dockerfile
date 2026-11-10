FROM debian:bookworm-slim

ARG USERNAME=agent
ARG UID=1000
ARG GID=1000
ARG NODE_VERSION=22.23.4
ARG PI_VERSION=1.5.0

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/${USERNAME}
ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.opencode/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        openssh-client \
        procps \
        unzip \
        wget \
        xclip \
        zip \
        bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# Node.js is required by Pi.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) node_arch="x64" ;; \
        arm64) node_arch="arm64" ;; \
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/node.tar.gz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.gz"; \
    tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1; \
    rm -f /tmp/node.tar.gz; \
    node --version; \
    npm --version

# Harness: Pi (user data is kept in ~/.pi/agent at runtime).
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && pi --version

# Harness: Codex (installed system-wide so the mounted ~/.codex holds only
# configuration, credentials, and sessions).
RUN set -eux; \
    curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/codex-install.sh; \
    CODEX_NON_INTERACTIVE=1 \
    CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_HOME=/opt/codex \
    sh /tmp/codex-install.sh; \
    rm -f /tmp/codex-install.sh

RUN groupadd --gid "${GID}" "${USERNAME}" \
    && useradd \
        --uid "${UID}" \
        --gid "${GID}" \
        --create-home \
        --shell /bin/bash \
        "${USERNAME}"

RUN mkdir -p \
        /workspace \
        /home/${USERNAME}/.config/opencode \
        /home/${USERNAME}/.cache/opencode \
        /home/${USERNAME}/.local/share/opencode \
        /home/${USERNAME}/.local/state/opencode \
        /home/${USERNAME}/.codex \
        /home/${USERNAME}/.pi/agent \
        /home/${USERNAME}/.config/herdr-core \
        /home/${USERNAME}/.local/state/herdr-core \
        /home/${USERNAME}/.config/herdr \
        /home/${USERNAME}/.local/state/herdr \
        /home/${USERNAME}/.local/state/agents-team \
        /home/${USERNAME}/.ssh \
    && chown -R "${USERNAME}:${USERNAME}" \
        /workspace \
        /home/${USERNAME}

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# Team mode: role instructions and the CLI/TUI launchers.
COPY team/ /opt/agents-team/
RUN chmod 0755 /opt/agents-team/team.sh \
        /opt/agents-team/tui.sh \
        /opt/agents-team/teamctl \
    && ln -s /opt/agents-team/team.sh /usr/local/bin/agents-team

USER ${USERNAME}

WORKDIR /home/${USERNAME}

# Harness: OpenCode 2 (installed into ~/.opencode/bin).
RUN set -eux; \
    curl -fsSL https://opencode.ai/v2/install -o /tmp/opencode-install.sh; \
    bash /tmp/opencode-install.sh --no-modify-path; \
    rm -f /tmp/opencode-install.sh

# Harness: Herdr Core (installed into ~/.local/bin, which is not mounted).
RUN set -eux; \
    curl -fsSL https://releases.herdr.dev/core/install.sh | sh; \
    hc --version

# Herdr TUI: a separate terminal application/server with spaces, tabs, and
# panes. It does not share running agents with herdr-core.
RUN set -eux; \
    curl -fsSL https://herdr.dev/install.sh | sh; \
    herdr --version

WORKDIR /workspace

RUN opencode --version \
    && codex --version \
    && pi --version \
    && hc --version \
    && herdr --version

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["opencode", "--standalone"]
