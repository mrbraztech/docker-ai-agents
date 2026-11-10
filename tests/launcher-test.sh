#!/usr/bin/env bash
#
# Launcher tests that do not need Docker. A stub docker records the compose
# invocation for the default and direct commands and for team mode.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log="${tmp}/docker.log"
project="${tmp}/project"
bin="${tmp}/bin"
home="${tmp}/home"

mkdir -p "$project" "$bin" "$home"

container_key=$(printf '%s' "$project" | sha256sum | cut -c1-16)
container_workspace="/workspaces/${container_key}"

cat >"${bin}/docker" <<'STUB'
#!/usr/bin/env bash

printf '%s\n' "$*" >>"${STUB_LOG:?}"

if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    exit 0
fi

if [ "${1:-}" = "compose" ]; then
    case " $* " in
        *" config --services "*)
            printf 'workspace\n'
            exit 0
            ;;
    esac
    exit 0
fi

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
    exit 0
fi

exit 0
STUB

chmod 0755 "${bin}/docker"

ln -s "${repo_dir}/agents.sh" "${bin}/agents"

export PATH="${bin}:${PATH}"
export HOME="${home}"
export STUB_LOG="${log}"
unset SSH_AUTH_SOCK || true

run_agents() {
    : >"${log}"
    (
        cd "$project"
        "$@"
    )
}

fail() {
    printf 'launcher test failed: %s\n' "$*" >&2
    if [ -s "$log" ]; then
        printf '%s\n' '--- docker log ---' >&2
        cat "$log" >&2
    fi
    exit 1
}

expect_log() {
    grep -Fq -- "$1" "$log" || fail "expected command containing: $1"
}

expect_no_log() {
    if grep -Fq -- "$1" "$log"; then
        fail "unexpected command containing: $1"
    fi
}

run_agents "${repo_dir}/agents.sh"
expect_log "run --rm --workdir ${container_workspace} --volume ${project}:${container_workspace} workspace bash"

run_agents "${repo_dir}/agents.sh" opencode --version
expect_log "run --rm --workdir ${container_workspace} --volume ${project}:${container_workspace} workspace opencode --standalone --version"

run_agents "${repo_dir}/agents.sh" codex --version
expect_log "run --rm --workdir ${container_workspace} --volume ${project}:${container_workspace} workspace codex --version"

run_agents "${repo_dir}/agents.sh" hc --version
expect_log "run --rm --workdir ${container_workspace} --volume ${project}:${container_workspace} workspace hc --version"

team_prefix="run --rm --workdir ${container_workspace} --volume ${project}:${container_workspace} -e AGENTS_TEAM_WORKSPACE_ID=${project} -e AGENTS_TEAM_WORKSPACE=${container_workspace} -e AGENTS_TEAM_BACKEND=tui -e AGENTS_TEAM_CODEX_SANDBOX=auto workspace /opt/agents-team/team.sh"

run_agents "${repo_dir}/agents.sh" team
expect_log "$team_prefix"

run_agents "${bin}/agents" team
expect_log "$team_prefix"

run_agents "${repo_dir}/agents.sh" team --fresh
expect_log "$team_prefix --fresh"

run_agents "${repo_dir}/agents.sh" team --cli
expect_log "${team_prefix/tui/cli}"

if run_agents "${repo_dir}/agents.sh" team extra >/dev/null 2>&1; then
    fail "team mode accepted an argument"
fi
expect_no_log "$team_prefix"

if run_agents "${repo_dir}/agents.sh" team --fresh extra >/dev/null 2>&1; then
    fail "team mode accepted an argument after --fresh"
fi
expect_no_log "$team_prefix --fresh"

printf 'launcher tests passed\n'
