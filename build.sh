#!/usr/bin/env bash

set -euo pipefail

HOST_HOME="${HOME:?HOME must be set}"

directories=(
    "${HOST_HOME}/.config/opencode"
    "${HOST_HOME}/.cache/opencode"
    "${HOST_HOME}/.local/share/opencode"
    "${HOST_HOME}/.local/state/opencode"
    "${HOST_HOME}/.codex"
    "${HOST_HOME}/.pi/agent"
    "${HOST_HOME}/.ssh"
)

mkdir -p "${directories[@]}"

for file in "${HOST_HOME}/.ssh/config" "${HOST_HOME}/.ssh/known_hosts"; do
    if [ ! -e "${file}" ]; then
        touch "${file}"
        chmod 600 "${file}"
    fi
done

docker build \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    -t agents-base:latest \
    .
