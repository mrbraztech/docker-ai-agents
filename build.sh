#!/usr/bin/env bash

set -euo pipefail

docker build \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    -t agents-base:latest \
    .