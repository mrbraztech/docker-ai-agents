#!/usr/bin/env sh
#
# agents.sh - run the containerized AI agents from any host directory.
#
# The script can be called directly or through launchers installed in
# ~/.local/bin (run "./agents.sh install" to create them).
#
# Compose selection:
#   1. --compose FILE / AGENTS_COMPOSE
#   2. compose.yaml (or compose.yml) found in the project root
#   3. the default compose.yaml shipped with this repository
#
# The project root is the Git top-level directory when the working directory
# is inside a repository. Outside Git, it is the nearest ancestor containing a
# compose file, or the working directory itself.

set -eu

PROG_NAME=$(basename -- "$0")

warn() {
    printf 'agents: %s\n' "$*" >&2
}

die() {
    printf 'agents: error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  agents [OPTIONS] [COMMAND [ARGS...]]

Commands:
  bash | sh             Open a shell inside the container (default).
  opencode              Run OpenCode 2.
  codex                 Run Codex.
  pi                    Run Pi.
  hc                    Run Herdr Core.
  team                  Start or reattach the planner/implementer team.
  team --fresh          Start new team conversations without deleting history.
  install [OPTIONS]     Create launchers in ~/.local/bin.
  build                 Build the default agents image.
  <command> [args...]   Run any command inside the container.

Options:
  -d, --dir DIR         Workspace directory (default: project root).
  -c, --compose FILE    Use FILE instead of the auto-detected compose file.
  -s, --service NAME    Compose service to run (default: workspace).
      --no-project-compose
                        Ignore a compose file found in the project root.
      --build           Build the default image before starting.
  -h, --help            Show this help.

Install options:
      --force           Replace launchers that already exist.
  -d, --dir DIR         Target directory (default: ~/.local/bin).

Environment:
  AGENTS_WORKSPACE_DIR  Same as --dir.
  AGENTS_COMPOSE        Same as --compose.
  AGENTS_SERVICE        Same as --service.
  AGENTS_AUTO_BUILD     Set to 0 to disable automatic image builds.
  AGENTS_OPENCODE_STANDALONE
                        Set to 0 to use OpenCode's shared background service.
  AGENTS_TEAM_PLANNER_MODEL
                        Model for the team planner (Codex).
  AGENTS_TEAM_IMPLEMENTER_MODEL
                        Model for the team implementer (OpenCode).

Examples:
  agents
  agents opencode
  agents codex --version
  agents team
  agents team --fresh
  agents --dir ~/src/project opencode
  cd ~/src/project && agents
EOF
}

resolve_self() {
    self=$0

    while [ -L "$self" ]; do
        self_dir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
        self_link=$(readlink -- "$self")
        case $self_link in
            /*) self=$self_link ;;
            *) self=$self_dir/$self_link ;;
        esac
    done

    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
    SCRIPT_PATH=$SCRIPT_DIR/$(basename -- "$self")
    REPO_DIR=$SCRIPT_DIR
    DEFAULT_COMPOSE=$REPO_DIR/compose.yaml
}

abs_dir() {
    CDPATH= cd -- "$1" && pwd -P
}

find_compose_up() {
    search_dir=$1

    while :; do
        for name in compose.yaml compose.yml; do
            if [ -f "$search_dir/$name" ]; then
                printf '%s\n' "$search_dir/$name"
                return 0
            fi
        done

        if [ "$search_dir" = "/" ]; then
            return 1
        fi

        search_dir=$(dirname -- "$search_dir")
    done
}

build_default_image() {
    printf 'agents: building the default image\n' >&2
    (CDPATH= cd -- "$REPO_DIR" && sh ./build.sh) || die "failed to build the default image"
}

ensure_default_image() {
    if docker image inspect agents-base:latest >/dev/null 2>&1; then
        return 0
    fi

    if [ "${AGENTS_AUTO_BUILD:-1}" = "0" ]; then
        die "image agents-base:latest not found; run build.sh or 'agents build'"
    fi

    warn "image agents-base:latest not found; building it now"
    build_default_image
}

ensure_host_dirs() {
    [ -n "${HOME:-}" ] || die "HOME is not set"

    for dir in \
        "$HOME/.config/opencode" \
        "$HOME/.cache/opencode" \
        "$HOME/.local/share/opencode" \
        "$HOME/.local/state/opencode" \
        "$HOME/.codex" \
        "$HOME/.pi/agent" \
        "$HOME/.ssh"
    do
        mkdir -p "$dir" 2>/dev/null || warn "could not create $dir"
    done

    for file in "$HOME/.ssh/config" "$HOME/.ssh/known_hosts"; do
        if [ ! -e "$file" ]; then
            (umask 077 && : >"$file") 2>/dev/null || warn "could not create $file"
        fi
    done
}

install_launchers() {
    [ -n "${HOME:-}" ] || die "HOME is not set"

    force=0
    bin_dir=${HOME}/.local/bin

    while [ $# -gt 0 ]; do
        case $1 in
            --force)
                force=1
                shift
                ;;
            -d | --dir)
                [ $# -ge 2 ] || die "option $1 requires an argument"
                bin_dir=$2
                shift 2
                ;;
            --dir=*)
                bin_dir=${1#*=}
                shift
                ;;
            -*)
                die "unknown install option: $1"
                ;;
            *)
                bin_dir=$1
                shift
                ;;
        esac
    done

    [ -n "$bin_dir" ] || die "could not determine the launcher directory"

    mkdir -p "$bin_dir" || die "could not create $bin_dir"

    for name in agents opencode codex pi hc; do
        target=$bin_dir/$name

        if [ -L "$target" ]; then
            current=$(readlink -f -- "$target" 2>/dev/null || true)
            if [ "$current" = "$SCRIPT_PATH" ]; then
                printf 'agents: %s already points to %s\n' "$target" "$SCRIPT_PATH" >&2
                continue
            fi
        fi

        if [ -e "$target" ] || [ -L "$target" ]; then
            if [ "$force" -ne 1 ]; then
                warn "$target already exists; use --force to replace it"
                continue
            fi
            rm -f "$target" || die "could not replace $target"
        fi

        ln -s "$SCRIPT_PATH" "$target" || die "could not create $target"
        printf 'agents: created %s -> %s\n' "$target" "$SCRIPT_PATH" >&2
    done

    case ":${PATH:-}:" in
        *":$bin_dir:"*) ;;
        *) warn "$bin_dir is not in PATH; add it to your shell profile" ;;
    esac
}

resolve_self

# Launchers are plain pass-throughs: every argument goes to the harness.
launcher_command=
case $PROG_NAME in
    opencode | codex | pi | hc | bash | sh)
        launcher_command=$PROG_NAME
        ;;
esac

subcommand_mode=0
case $PROG_NAME in
    agents | agents.sh)
        subcommand_mode=1
        ;;
esac

workspace_arg=${AGENTS_WORKSPACE_DIR:-${WORKSPACE_DIR:-}}
compose_arg=${AGENTS_COMPOSE:-}
service=${AGENTS_SERVICE:-workspace}
build_requested=0
use_project_compose=1
command=
have_command=0
team_mode=0
team_fresh=0

if [ -n "$launcher_command" ]; then
    command=$launcher_command
    have_command=1
else
    while [ $# -gt 0 ]; do
        case $1 in
            -d | --dir)
                [ $# -ge 2 ] || die "option $1 requires an argument"
                workspace_arg=$2
                shift 2
                ;;
            --dir=*)
                workspace_arg=${1#*=}
                shift
                ;;
            -c | --compose)
                [ $# -ge 2 ] || die "option $1 requires an argument"
                compose_arg=$2
                shift 2
                ;;
            --compose=*)
                compose_arg=${1#*=}
                shift
                ;;
            -s | --service)
                [ $# -ge 2 ] || die "option $1 requires an argument"
                service=$2
                shift 2
                ;;
            --service=*)
                service=${1#*=}
                shift
                ;;
            --no-project-compose)
                use_project_compose=0
                shift
                ;;
            --build)
                build_requested=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "unknown option: $1 (try --help)"
                ;;
            *)
                command=$1
                have_command=1
                shift
                break
                ;;
        esac
    done
fi

if [ "$have_command" -eq 0 ]; then
    if [ $# -gt 0 ]; then
        command=$1
        shift
    else
        command=bash
    fi
fi

if [ "$subcommand_mode" -eq 1 ]; then
    case $command in
        install)
            install_launchers "$@"
            exit 0
            ;;
        build)
            build_default_image
            exit 0
            ;;
        team)
            while [ $# -gt 0 ]; do
                case $1 in
                    --fresh)
                        team_fresh=1
                        shift
                        ;;
                    *)
                        die "team only accepts --fresh"
                        ;;
                esac
            done
            command=/opt/agents-team/team.sh
            team_mode=1
            if [ "$team_fresh" -eq 1 ]; then
                set -- --fresh
            else
                set --
            fi
            ;;
        help)
            usage
            exit 0
            ;;
    esac
fi

# OpenCode's managed background service registers itself in the shared state
# directory. Containers started from different directories share that
# directory and keep replacing each other's registration, which shows up as a
# "restarting service" loop. Interactive commands therefore use a private
# server by default. Set AGENTS_OPENCODE_STANDALONE=0 to use the shared
# service instead.
if [ "${AGENTS_OPENCODE_STANDALONE:-1}" != "0" ] && [ "$(basename -- "$command")" = "opencode" ]; then
    opencode_first_arg=
    opencode_skip_value=0

    for arg in "$@"; do
        if [ "$opencode_skip_value" -eq 1 ]; then
            opencode_skip_value=0
            continue
        fi

        case $arg in
            --)
                break
                ;;
            -s | --session | --server | --log-level | --prompt | --completions)
                opencode_skip_value=1
                ;;
            -*)
                ;;
            *)
                opencode_first_arg=$arg
                break
                ;;
        esac
    done

    opencode_has_server=0
    opencode_has_standalone=0

    for arg in "$@"; do
        case $arg in
            --server | --server=*)
                opencode_has_server=1
                ;;
            --standalone)
                opencode_has_standalone=1
                ;;
        esac
    done

    case $opencode_first_arg in
        service | api | auth | mcp | plugin | models | stats | session | upgrade | update | uninstall | acp | serve | reload | pair | debug)
            opencode_shared_only=1
            ;;
        *)
            opencode_shared_only=0
            ;;
    esac

    if [ "$opencode_has_server" -eq 0 ] && [ "$opencode_has_standalone" -eq 0 ] && [ "$opencode_shared_only" -eq 0 ]; then
        set -- --standalone "$@"
    fi
fi

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose is not available"

if [ -n "$workspace_arg" ]; then
    [ -d "$workspace_arg" ] || die "workspace directory not found: $workspace_arg"
    start_dir=$(abs_dir "$workspace_arg")
else
    start_dir=$(abs_dir "$PWD")
fi

if command -v git >/dev/null 2>&1 && git_root=$(git -C "$start_dir" rev-parse --show-toplevel 2>/dev/null); then
    project_root=$(abs_dir "$git_root")
elif project_compose=$(find_compose_up "$start_dir"); then
    project_root=$(dirname -- "$project_compose")
else
    project_root=$start_dir
fi

if [ -n "$workspace_arg" ]; then
    workspace_dir=$start_dir
else
    workspace_dir=$project_root
fi

compose_from_project=0

if [ -n "$compose_arg" ]; then
    [ -f "$compose_arg" ] || die "compose file not found: $compose_arg"
    compose_file=$(CDPATH= cd -- "$(dirname -- "$compose_arg")" && pwd -P)/$(basename -- "$compose_arg")
    compose_dir=$(dirname -- "$compose_file")
elif [ "$use_project_compose" -eq 1 ] && [ -f "$project_root/compose.yaml" ]; then
    compose_file=$project_root/compose.yaml
    compose_dir=$project_root
    compose_from_project=1
elif [ "$use_project_compose" -eq 1 ] && [ -f "$project_root/compose.yml" ]; then
    compose_file=$project_root/compose.yml
    compose_dir=$project_root
    compose_from_project=1
else
    [ -f "$DEFAULT_COMPOSE" ] || die "default compose file not found: $DEFAULT_COMPOSE"
    compose_file=$DEFAULT_COMPOSE
    compose_dir=$REPO_DIR
fi

# A project compose file that does not define the agents service cannot run
# the requested command. Fall back to the default compose in that case,
# unless the service was chosen explicitly.
if [ "$compose_from_project" -eq 1 ] && [ -z "${AGENTS_SERVICE:-}" ]; then
    if services=$(docker compose -f "$compose_file" --project-directory "$compose_dir" config --services 2>/dev/null); then
        if ! printf '%s\n' "$services" | grep -Fxq "$service"; then
            warn "$compose_file does not define service '$service'; using the default compose"
            [ -f "$DEFAULT_COMPOSE" ] || die "default compose file not found: $DEFAULT_COMPOSE"
            compose_file=$DEFAULT_COMPOSE
            compose_dir=$REPO_DIR
            compose_from_project=0
        fi
    fi
fi

export WORKSPACE_DIR="$workspace_dir"

if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
    warn "SSH_AUTH_SOCK is not a running SSH agent; continuing without SSH forwarding"
    SSH_AUTH_SOCK=/dev/null
fi
export SSH_AUTH_SOCK

: "${DISPLAY:=}"
: "${GH_TOKEN:=}"
: "${AGENTS_TEAM_PLANNER_MODEL:=}"
: "${AGENTS_TEAM_IMPLEMENTER_MODEL:=}"
export DISPLAY GH_TOKEN AGENTS_TEAM_PLANNER_MODEL AGENTS_TEAM_IMPLEMENTER_MODEL

ensure_host_dirs

if [ "$build_requested" -eq 1 ]; then
    build_default_image
elif [ "$compose_from_project" -eq 0 ]; then
    ensure_default_image
fi

if [ "$team_mode" -eq 1 ]; then
    # The canonical host path distinguishes workspaces that are all mounted at
    # /workspace inside the container.
    exec docker compose \
        -f "$compose_file" \
        --project-directory "$compose_dir" \
        run --rm -e "AGENTS_TEAM_WORKSPACE_ID=$workspace_dir" \
        "$service" "$command" "$@"
fi

exec docker compose \
    -f "$compose_file" \
    --project-directory "$compose_dir" \
    run --rm "$service" "$command" "$@"
