# AI Agents Workspace

Containerized development environment for AI coding agents. It provides a
reproducible Debian-based workspace with [OpenCode](https://opencode.ai) and
[Codex](https://chatgpt.com/codex) pre-installed, running as a non-root user
with the repository mounted at `/workspace`.

## Contents

| File            | Purpose                                              |
| --------------- | ---------------------------------------------------- |
| `Dockerfile`    | Builds the base image with the required tooling.     |
| `build.sh`      | Builds the image using the host user's UID/GID.      |
| `compose.yaml`  | Runs the workspace container with mounts and limits. |

## Requirements

- Docker Engine
- Docker Compose v2
- A SSH agent running on the host (`SSH_AUTH_SOCK`)
- OpenCode/Codex credentials on the host (see [Configuration](#configuration))

## Building the image

```sh
./build.sh
```

The script builds `agents-base:latest` and forwards `UID`/`GID` from the host so
files created inside the container keep the same ownership as on the host.

To customize the defaults:

```sh
docker build \
  --build-arg USERNAME=agent \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  -t agents-base:latest .
```

## Running

```sh
docker compose run --rm workspace
```

The container starts OpenCode by default. To open a shell instead:

```sh
docker compose run --rm workspace bash
```

## Mounts

The compose file mounts:

- `${WORKSPACE_DIR:-.}` at `/workspace` — the project being worked on.
- `~/.config/opencode` at `/home/agent/.config/opencode` — shared OpenCode config.
- `~/.config/codex` at `/home/agent/.codex` — persistent Codex data.
- Named volumes `opencode-share` and `opencode-state` — sessions and state.
- The host SSH agent socket at `/ssh-agent` (private keys are never mounted).
- `~/.ssh/config` and `~/.ssh/known_hosts` (read-only).
- `/tmp/.X11-unix` (read-only) for X11 clipboard support.

## Configuration

The compose file reads environment variables from two files owned by the host
user:

- `~/.config/opencode/9router.env`
- `~/.config/opencode/go.env`

Additional variables are forwarded from the host environment:

| Variable        | Description                                   |
| --------------- | --------------------------------------------- |
| `WORKSPACE_DIR` | Host directory mounted as `/workspace`.       |
| `DISPLAY`       | X11 display used for clipboard integration.   |
| `SSH_AUTH_SOCK` | Path to the host SSH agent socket.            |
| `GH_TOKEN`      | GitHub token exposed to the agents.           |

Make sure `SSH_AUTH_SOCK` is set and the required env files exist before
starting the container.

## Security

The container runs with:

- `no-new-privileges:true`
- all Linux capabilities dropped (`cap_drop: ALL`)
- `tmpfs` mounts for `/tmp` and `/run`

SSH private keys are never mounted; only the agent socket is shared.

## Notes

- This environment is intended for development only. It does not deploy
  anything.
- The `codex` and `opencode` CLIs are verified at image build time via
  `--version`.
