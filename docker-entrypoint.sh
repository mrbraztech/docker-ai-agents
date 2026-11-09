#!/usr/bin/env bash

set -euo pipefail

ensure_dir() {
    local dir="$1"

    if [ -d "${dir}" ]; then
        if [ ! -w "${dir}" ]; then
            printf 'warning: %s is not writable by uid %s\n' "${dir}" "$(id -u)" >&2
        fi
        return 0
    fi

    if ! mkdir -p "${dir}" 2>/dev/null; then
        printf 'warning: could not create %s\n' "${dir}" >&2
    fi
}

ensure_dir "${HOME}/.config/opencode"
ensure_dir "${HOME}/.cache/opencode"
ensure_dir "${HOME}/.local/share/opencode"
ensure_dir "${HOME}/.local/state/opencode"
ensure_dir "${HOME}/.codex"
ensure_dir "${HOME}/.pi/agent"
ensure_dir "${HOME}/.ssh"

# OpenCode (including the opencode-go provider) and Pi read the OpenCode
# Zen/Go API key from OPENCODE_API_KEY. Existing go.env files may still use
# OPENCODE_GO_API_KEY, so accept it as an alias.
if [ -n "${OPENCODE_GO_API_KEY:-}" ] && [ -z "${OPENCODE_API_KEY:-}" ]; then
    export OPENCODE_API_KEY="${OPENCODE_GO_API_KEY}"
fi

exec "$@"
