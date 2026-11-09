# AI Agents Workspace

Containerized development environment for AI coding agents. It provides a
reproducible Debian-based workspace with [OpenCode 2](https://opencode.ai),
[Codex](https://chatgpt.com/codex), [Pi](https://pi.dev), and
[Herdr Core](https://herdr.dev/core/) pre-installed, running as a non-root user
with the repository mounted at `/workspace`.

## Contents

| File                   | Purpose                                                  |
| ---------------------- | -------------------------------------------------------- |
| `Dockerfile`           | Builds the base image with the required tooling.         |
| `build.sh`             | Prepares host directories and builds the image.          |
| `compose.yaml`         | Runs the workspace container with mounts and limits.     |
| `docker-entrypoint.sh` | Creates missing data directories and starts the command. |
| `agents.sh`            | Runs any agent from any directory and installs launchers. |
| `team/`                | Team mode role instructions and the team launcher.        |

## Requirements

- Docker Engine
- Docker Compose v2.24+ (for optional `env_file` entries)
- A SSH agent running on the host (`SSH_AUTH_SOCK`)
- OpenCode/Codex/Pi credentials on the host (see [Configuration](#configuration))

## Building the image

```sh
./build.sh
```

The script creates the host directories used by the bind mounts (idempotently),
then builds `agents-base:latest` forwarding `UID`/`GID` from the host so files
created inside the container keep the same ownership as on the host.
`docker-entrypoint.sh` is copied into the image, so rebuild after modifying it.

To customize the defaults:

```sh
docker build \
  --build-arg USERNAME=agent \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  -t agents-base:latest .
```

## Running

`agents.sh` can be executed from any directory on the host. It mounts the
current project as `/workspace` and starts the requested harness:

```sh
/absolute/path/to/agents.sh              # Bash shell (default)
/absolute/path/to/agents.sh opencode     # OpenCode
/absolute/path/to/agents.sh codex        # Codex
/absolute/path/to/agents.sh pi           # Pi
/absolute/path/to/agents.sh hc           # Herdr Core
/absolute/path/to/agents.sh team         # Planner/implementer team
```

When no command is given, the script opens a Bash shell inside the container.

OpenCode runs with `--standalone` by default. This gives each container a
private background server and prevents the shared `service.json` from
triggering a restart loop when several containers run at the same time. Set
`AGENTS_OPENCODE_STANDALONE=0` to use the shared background service instead.

The workspace directory is resolved as follows:

1. `--dir DIR` or `AGENTS_WORKSPACE_DIR`, when set.
2. The Git top-level directory, when the current directory is inside a
   repository.
3. The nearest ancestor containing a compose file, when outside Git.
4. The current directory.

Use `--dir .` to always mount the current directory, even inside a
repository.

### Compose selection

For each invocation the script chooses the compose file in this order:

1. `--compose FILE` or `AGENTS_COMPOSE`.
2. A `compose.yaml` (or `compose.yml`) found in the project root.
3. The default `compose.yaml` from this repository.

When a project compose file is selected, the service `workspace` is used by
default. If that service is not defined, the script falls back to the default
compose file. Set `--service NAME` or `AGENTS_SERVICE` to use a different
service. Use `--no-project-compose` to ignore the project compose file.

The image `agents-base:latest` is built automatically when it does not exist.
Set `AGENTS_AUTO_BUILD=0` to disable that behavior, or run `agents.sh build`.
A project compose file is responsible for building its own images.

### Launchers in `~/.local/bin`

Install launchers that call `agents.sh` and can be used from any directory:

```sh
/absolute/path/to/agents.sh install
```

This creates symlinks for `agents`, `opencode`, `codex`, `pi`, and `hc` in
`~/.local/bin`. Existing files are preserved unless `--force` is passed:

```sh
/absolute/path/to/agents.sh install --force
/absolute/path/to/agents.sh install --dir ~/bin
```

Make sure `~/.local/bin` is in `PATH`. Launchers pass every argument directly
to the harness, so `opencode --version` behaves as expected. Use the `agents`
command when wrapper options are needed:

```sh
agents --dir ~/src/project opencode
agents --service workspace --build codex
agents team
```

The container can also be started directly with Compose:

```sh
docker compose run --rm workspace
```

The entrypoint is idempotent: every start only ensures that the required
directories exist and then executes the requested command, so the same
container definition can be run repeatedly without side effects.

### Team mode

```sh
/absolute/path/to/agents.sh team
/absolute/path/to/agents.sh team --fresh
```

`team` is opt-in. The default Bash shell and the direct `opencode`, `codex`,
`pi`, and `hc` commands keep their existing behavior.

Team mode uses one interactive container for the selected project, one Herdr
Core instance inside that container, and exactly two named roles:

- `planner`: Codex. It talks to the user, inspects the repository, presents a
  plan, waits for explicit user approval, delegates the approved work, and
  reviews the result.
- `implementer`: OpenCode. It receives delegated tasks, changes the project,
  runs the relevant checks, and reports changed files, test results, and
  blockers back to the planner.

The team launcher starts or resumes the implementer and planner and attaches
the terminal to the planner. Detach with `ctrl+\`. The launcher and its
`docker compose run` container then exit. Running `agents.sh team` again opens a
new container and resumes the native conversations associated with the same
host workspace and role. Live Herdr terminals are reused while that container is
running; Herdr settings, terminal labels, and state remain in the named volumes.

The planner must show the plan and ask for explicit approval before any
implementation handoff. The approval is part of the planner role instructions,
not a separate approval service.

#### Sessions and lifecycle

The launcher checks the live Herdr terminals before starting anything:

- A live terminal named `planner` or `implementer` is reused only when its
  `role` and `workspace` labels match the current invocation. A live terminal
  from another workspace, or one without usable labels, is left untouched and
  the launcher stops with a clear error instead of attaching to it. Matching
  live terminals are never restarted, even when they are busy or waiting for
  input.
- A terminal with an unknown state is reused only after its role and workspace
  labels validate. If the state or labels cannot be read or do not match, the
  launcher stops without attaching to or modifying the terminal.
- A finished terminal is kept until its replacement terminal has been started
  and its workspace/role/session labels have been confirmed. A saved session
  that is being resumed keeps the previous record because the launcher cannot
  prove that the native TUI loaded it. A new or fresh session removes the
  previous record of the same workspace and role only after the new labels are
  confirmed. If previous records cannot be listed, cleanup is skipped and all
  records are kept.
- Missing roles are started, so a session that lost only the implementer gets
  it back without restarting the planner.

The association is stored in supported Herdr terminal labels: `role`,
`workspace`, `session`, and `task-state`. `agents.sh` passes the canonical host
workspace path to the container as `AGENTS_TEAM_WORKSPACE_ID`; this keeps
different host directories distinct even though all of them are mounted at
`/workspace`. A saved session is reused only when its role, workspace, and ID
are all valid. A missing, corrupt, stale, or cross-workspace association starts
a new conversation instead of adopting unrelated history.

Native conversation continuity uses each agent's supported resume mechanism:

- OpenCode is started with `opencode --session <id>`. The ID is generated with
  the `ses_` prefix when a new conversation is needed.
- Codex has no CLI flag that chooses the session ID of a new interactive
  terminal. For a new or fresh Codex session, the launcher first runs
  `codex exec --json` with a fixed bootstrap instruction that only asks for
  `READY`, does not inspect or modify the workspace, and starts no work. It
  captures the exact `thread_id` from the `thread.started` event and requires
  `turn.completed` to confirm that the bootstrap turn finished; together these
  events identify the persisted session. It then opens the interactive TUI with
  `codex resume <id>`. The bootstrap is never used to resume an existing ID and
  never replays an implementation task.

`agents.sh team --fresh` starts new native conversations for roles that are not
live. It updates the labels to the new IDs, leaves the previous Codex and
OpenCode histories in their mounted data directories, and does not kill or
replace live terminals. If live terminals are present, fresh mode reports that
they were kept. Finished records are removed only after the new association is
confirmed.

A saved session ID is resumed by opening `codex resume <id>` explicitly. There
is no non-mutative signal that proves the TUI loaded the saved thread, so the
launcher does not claim that transfer succeeded and keeps the previous record.
If the saved ID is broken, the terminal exits and the user sees a clear resume
error; the launcher never falls back to `--last`, another session, or an
automatic replay. Run `agents team --fresh` when a new conversation is wanted.
For a new ID created by the neutral bootstrap, `thread.started` plus
`turn.completed` is evidence that Codex persisted the session. OpenCode session
IDs are checked against `opencode session list` before reuse; a missing ID
starts a new conversation.

When a terminal ends during a task, Herdr marks it as finished and the native
conversation remains available. The launcher does not send the previous task
again. The planner records delegation state in the `task-state` label:
`in_progress` before delegating, `completed` after validating the report, and
`in_progress` or `unknown` for interrupted work. The planner must not delegate
unless both role labels were set to `in_progress`. On recovery, an
`in_progress`/`unknown` state requires inspecting the repository and history,
reporting uncertainty, and asking the user for explicit confirmation before
further implementation. Restored history is never treated as proof that the
task succeeded.


#### Role instructions

The role files are version-controlled:

- `team/planner.md`
- `team/implementer.md`

The image copies them to `/opt/agents-team/`. At startup the launcher passes
them to the matching agent through supported loading mechanisms:

- Codex: `-c developer_instructions=...`, read from
  `/opt/agents-team/planner.md`.
- OpenCode: a generated config with the top-level `instructions` array,
  pointing to `/opt/agents-team/implementer.md`, loaded with
  `OPENCODE_CONFIG` and `opencode --standalone`.

Both mechanisms leave the agents' own base instructions in place. Change a
role file in the repository and rebuild the image to distribute the change.

#### Model configuration

The default model values are empty. In that case each agent uses the model from
its existing user configuration. To select models for the team, set:

```sh
AGENTS_TEAM_PLANNER_MODEL=... AGENTS_TEAM_IMPLEMENTER_MODEL=... \
  /absolute/path/to/agents.sh team
```

- `AGENTS_TEAM_PLANNER_MODEL` is passed to Codex with `-m/--model`.
- `AGENTS_TEAM_IMPLEMENTER_MODEL` is written to OpenCode's `model` config field.

The values are provider-neutral. Use the model identifier accepted by the
corresponding CLI or config, for example a `provider/model` value for OpenCode.
No provider-specific model name is hardcoded in the repository.

#### Persistence and compatibility

Team mode reuses the existing `herdr-config` and `herdr-state` Docker named
volumes, so Herdr settings, terminal labels, and state survive container
re-creation. Because that state is shared, a team start refuses to attach to a
live role whose workspace label does not match the current host workspace. Stop
that team or run `agents.sh --dir <workspace> team` for the matching directory.
The native Codex and OpenCode conversations also survive because
their data directories are bind-mounted. Live terminals belong to the container
process and are reused only while it is running. `team --fresh` does not delete
those native histories. The existing bind mounts for the project, agent
credentials, sessions, and SSH agent are unchanged.

Project compose files continue to work. A project service must use an image
that extends `agents-base` (directly or through its own Dockerfile), because
that image provides `/opt/agents-team/team.sh` and the role files. The launcher
does not add a new container, a second Herdr Core, a Docker socket, or new
security settings.

#### Codex write isolation is unresolved

Codex is instructed not to edit project files. This is a prompt-level
behavioral rule, not a filesystem sandbox. The repository does not implement or
verify technical write isolation for the Codex process, and prompt instructions
do not provide filesystem isolation. Treat Codex write isolation as unresolved,
review the changes, and use the implementer as the role that performs edits and
tests.

## Mounts and persistence

All configuration, credentials, and session data are persisted, either on the
host or in Docker named volumes, so they survive container restarts,
re-creation, and `docker compose down`.

| Host path                        | Container path                    | Contents                                       |
| -------------------------------- | --------------------------------- | ---------------------------------------------- |
| `${WORKSPACE_DIR:-.}`            | `/workspace`                      | Project being worked on.                       |
| `${HOME}/.config/opencode`       | `/home/agent/.config/opencode`    | OpenCode configuration.                        |
| `${HOME}/.local/share/opencode`  | `/home/agent/.local/share/opencode` | OpenCode credentials and sessions.           |
| `${HOME}/.local/state/opencode`  | `/home/agent/.local/state/opencode` | OpenCode state.                              |
| `${HOME}/.cache/opencode`        | `/home/agent/.cache/opencode`     | OpenCode cache and logs.                       |
| `${HOME}/.codex`                 | `/home/agent/.codex`              | Codex config, credentials, history, sessions.  |
| `${HOME}/.pi`                    | `/home/agent/.pi`                 | Pi configuration, credentials, and sessions.   |

Herdr Core uses Docker named volumes:

| Volume          | Container path                          | Contents                    |
| --------------- | --------------------------------------- | --------------------------- |
| `herdr-config`  | `/home/agent/.config/herdr-core`        | Herdr Core settings.        |
| `herdr-state`   | `/home/agent/.local/state/herdr-core`   | Herdr Core runtime state.   |

The named volumes survive `docker compose down`. Remove them with
`docker compose down -v`.

Additional mounts:

- The host SSH agent socket at `/ssh-agent` (private keys are never mounted).
- `~/.ssh/config` and `~/.ssh/known_hosts` (read-only).
- `/tmp/.X11-unix` (read-only) for X11 clipboard support.

Codex and Pi binaries are installed system-wide (`/opt/codex` and
`/usr/local/bin`), so the mounted home directories contain only user data and
never hide the installed executables. OpenCode 2 is installed into
`~/.opencode/bin`, which is not mounted, so the mounted configuration
directories never hide the binary either. Herdr Core is installed into
`~/.local/bin`, which is also not mounted.

OpenCode 2 stores credentials in the SQLite database
`~/.local/share/opencode/opencode.db`. The database lives inside the mounted
data directory, so logins survive container re-creation. On first start, V2
imports supported credentials from the legacy
`~/.local/share/opencode/auth.json` and migrates terminal settings from
`~/.config/opencode/tui.json` to `~/.config/opencode/cli.json`.

## Configuration

The compose file reads environment variables from two files owned by the host
user. Both are optional:

- `~/.config/opencode/9router.env`
- `~/.config/opencode/go.env`

Additional variables are forwarded from the host environment:

| Variable        | Description                                   |
| --------------- | --------------------------------------------- |
| `WORKSPACE_DIR` | Host directory mounted as `/workspace`.       |
| `DISPLAY`       | X11 display used for clipboard integration.   |
| `SSH_AUTH_SOCK` | Path to the host SSH agent socket.            |
| `GH_TOKEN`      | GitHub token exposed to the agents.           |

`agents.sh` also reads these variables:

| Variable               | Description                                                    |
| ---------------------- | -------------------------------------------------------------- |
| `AGENTS_WORKSPACE_DIR` | Workspace directory; same as `--dir`.                          |
| `AGENTS_COMPOSE`       | Compose file to use; same as `--compose`.                      |
| `AGENTS_SERVICE`       | Compose service to run; same as `--service`.                   |
| `AGENTS_AUTO_BUILD`    | Set to `0` to disable automatic builds of the default image.   |
| `AGENTS_OPENCODE_STANDALONE` | Set to `0` to use OpenCode's shared background service.  |
| `AGENTS_TEAM_PLANNER_MODEL` | Model passed to the team planner (Codex) with `-m`.      |
| `AGENTS_TEAM_IMPLEMENTER_MODEL` | Model written to the team implementer (OpenCode) config. |
| `AGENTS_TEAM_WORKSPACE_ID` | Internal: canonical host workspace passed by `agents.sh team`. |

If a `WORKSPACE_DIR` is already exported, `agents.sh` uses it as the workspace
directory unless `--dir` or `AGENTS_WORKSPACE_DIR` is given.

Before starting the container, `agents.sh` creates the host directories used
by the bind mounts, so Docker does not create them as root. If
`SSH_AUTH_SOCK` is missing or does not point to a running agent, the script
warns and continues without SSH forwarding.

OpenCode (including the `opencode-go` provider) and Pi read the OpenCode
Zen/Go API key from `OPENCODE_API_KEY`. If an existing `go.env` uses the
legacy `OPENCODE_GO_API_KEY` name, the entrypoint exports it as
`OPENCODE_API_KEY` for compatibility.

### Credentials missing after switching to bind mounts

An older version of `compose.yaml` stored OpenCode data in the named volumes
`opencode-share` and `opencode-state`. Credentials created with that setup are
not in `~/.local/share/opencode` and therefore disappear after switching to
bind mounts. Check `docker volume ls` for the exact name (the Compose project
name is `ai-agents`) and migrate the old volume once:

```sh
docker run --rm \
  -v ai-agents_opencode-share:/from \
  -v "${HOME}/.local/share/opencode:/to" \
  alpine sh -c 'cp -a /from/. /to/'
```

Check which credential file OpenCode is using with:

```sh
docker compose run --rm workspace opencode auth list
```

### OpenCode keeps restarting the background service

OpenCode registers its shared background service in
`~/.local/state/opencode/service.json`. That directory is bind-mounted from
the host, so every container that shares it overwrites the registration of the
others. The service logs then show:

```text
managed service registration replaced; shutting down
```

The client reconnects and opens a new service, which is replaced again, so the
TUI appears stuck restarting the service.

The `agents.sh` launchers avoid this by running interactive OpenCode commands
with `--standalone`, which starts a private server for each container. The
default image command does the same. To use the shared service anyway, set
`AGENTS_OPENCODE_STANDALONE=0`; in that case, do not run multiple containers
at the same time, and stop any OpenCode instance on the host that uses the same
state directory.

To recover a loop that is already running, close the other instances first and
then restart the service inside the container:

```sh
opencode service stop
opencode service start
opencode service status
```

## Security

The container runs with:

- `no-new-privileges:true`
- all Linux capabilities dropped (`cap_drop: ALL`)
- `tmpfs` mounts for `/tmp` and `/run`

SSH private keys are never mounted; only the agent socket is shared. The
mounted `~/.codex`, `~/.pi`, and OpenCode data directories contain credentials
and must be treated as secrets.

Team mode keeps these controls. It does not mount the Docker socket, add
containers, or change the capability, privilege, or `tmpfs` settings. Codex
must not edit project files, but that restriction is not enforced by a
filesystem sandbox; see
[Codex write isolation is unresolved](#codex-write-isolation-is-unresolved).

## Herdr Core

Herdr Core is installed with the official installer
(`https://releases.herdr.dev/core/install.sh`) as the `hc` command. It runs
programs and coding agents in terminals that stay alive inside the container:

```sh
hc run --bg --name web bun dev
hc ls
hc attach web
```

Herdr Core stores its settings and state in the `herdr-config` and
`herdr-state` Docker named volumes, so they are preserved when the container is
re-created.

Team mode uses the same core and volumes. It starts both roles with
`hc run --bg --name ...`, reuses live role terminals, and removes finished
ones before launching them again. See [Team mode](#team-mode).

## Notes

- This environment is intended for development only. It does not deploy
  anything.
- The `codex`, `opencode`, `pi`, and `hc` CLIs are verified at image build time
  via `--version`.
- OpenCode 2 is installed with the V2 installer
  (`https://opencode.ai/v2/install`). V1 plugins and V1 server API integrations
  are not compatible with V2.
- To update the harnesses, rebuild the image. Rebuilding does not modify the
  persisted configuration, credentials, or sessions on the host.
