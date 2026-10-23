FROM debian:bookworm-slim

ARG USERNAME=agent
ARG UID=1000
ARG GID=1000

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
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local/share/opencode \
        /home/${USERNAME}/.local/state/opencode \
        /home/${USERNAME}/.ssh \
    && chown -R "${USERNAME}:${USERNAME}" \
        /workspace \
        /home/${USERNAME}

USER ${USERNAME}

WORKDIR /home/${USERNAME}

# Harness: OpenCode
RUN curl -fsSL https://opencode.ai/install | bash

# Harness: Codex
RUN curl -fsSL https://chatgpt.com/codex/install.sh | \
    CODEX_NON_INTERACTIVE=1 sh

WORKDIR /workspace

RUN opencode --version \
    && codex --version

CMD ["opencode"]