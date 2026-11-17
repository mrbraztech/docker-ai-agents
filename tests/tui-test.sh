#!/usr/bin/env bash
#
# Herdr TUI backend tests with stub herdr, codex, and opencode binaries.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin="${tmp}/bin"
state="${tmp}/state"
runtime="${tmp}/runtime"
herdr_state="${tmp}/herdr-state"
herdr_log="${tmp}/herdr.log"
codex_log="${tmp}/codex.log"
opencode_log="${tmp}/opencode.log"
hc_log="${tmp}/hc.log"
tui_log="${tmp}/tui.log"

mkdir -p "$bin" "$state" "$runtime" "$herdr_state"

cat >"${bin}/herdr" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'herdr %s\n' "$*" >>"${STUB_HERDR_LOG:?}"

session=
if [ "${1:-}" = "--session" ]; then
    session=$2
    shift 2
fi

command_name=${1:-}
shift || true

state_dir="${STUB_HERDR_STATE:?}"
counter() {
    local name=$1 value
    value=$(cat "${state_dir}/${name}" 2>/dev/null || printf '0')
    value=$((value + 1))
    printf '%s' "$value" >"${state_dir}/${name}"
    printf '%s' "$value"
}

case "$command_name" in
    server)
        : >"${state_dir}/server"
        printf '{"server":"started"}\n'
        ;;
    status)
        if [ -f "${state_dir}/server" ]; then
            printf 'server:\n  status: running\n'
        else
            printf 'server:\n  status: not running\n'
        fi
        ;;
    session)
        subcommand=${1:-}
        case "$subcommand" in
            stop)
                rm -f "${state_dir}/server"
                printf 'stopped\n'
                ;;
            delete)
                printf 'deleted\n'
                ;;
        esac
        ;;
    workspace)
        subcommand=${1:-}
        if [ "$subcommand" = "create" ]; then
            cwd=
            label=
            while [ $# -gt 0 ]; do
                case "$1" in
                    --cwd) cwd=$2; shift 2 ;;
                    --label) label=$2; shift 2 ;;
                    --no-focus) shift ;;
                    *) shift ;;
                esac
            done
            printf '{"id":"cli:workspace:create","result":{"workspace":{"workspace_id":"w1","label":"%s","cwd":"%s"},"root_pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"},"tab":{"tab_id":"w1:t1","label":"1","workspace_id":"w1"}}}\n' "$label" "$cwd"
        fi
        ;;
    tab)
        subcommand=${1:-}
        shift || true
        case "$subcommand" in
            rename)
                printf '{"id":"cli:tab:rename","result":{"type":"tab_renamed"}}\n'
                ;;
        esac
        ;;
    pane)
        subcommand=${1:-}
        shift || true
        if [ "$subcommand" = "split" ]; then
            printf '{"id":"cli:pane:split","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","cwd":"/workspace"}}}\n'
        fi
        ;;
    agent)
        subcommand=${1:-}
        shift || true
        case "$subcommand" in
            start)
                printf '{"id":"cli:agent:start","result":{"type":"agent_started","name":"%s"}}\n' "${1:-}"
                ;;
            prompt)
                printf '{"id":"cli:agent:prompt","result":{"type":"agent_prompt"}}\n'
                ;;
            wait)
                printf '{"id":"cli:agent:wait","result":{"type":"agent_wait","ended":true,"status":"idle"}}\n'
                ;;
            read)
                printf 'agent output\n'
                ;;
        esac
        ;;
    "")
        printf '{"attached":"tui"}\n'
        ;;
esac
STUB

cat >"${bin}/codex" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'codex %s\n' "$*" >>"${STUB_CODEX_LOG:?}"

case "${1:-}" in
    exec)
        counter=$(cat "${STUB_CODEX_STATE:?}/counter" 2>/dev/null || printf '0')
        counter=$((counter + 1))
        printf '%s' "$counter" >"${STUB_CODEX_STATE}/counter"
        thread=$(printf '00000000-0000-4000-8000-%012d' "$counter")
        printf '%s\n' "$thread" >>"${STUB_CODEX_STATE}/threads"
        printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
        printf '{"type":"turn.completed","usage":{}}\n'
        ;;
    --version)
        printf 'codex-cli 0.167.0\n'
        ;;
esac
STUB

cat >"${bin}/opencode" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'opencode %s\n' "$*" >>"${STUB_OPENCODE_LOG:?}"

case "${1:-}" in
    session)
        if [ "${2:-}" = "list" ]; then
            if [ -f "${STUB_OPENCODE_STATE:?}/sessions" ]; then
                jq -R -s --arg workspace "${STUB_OPENCODE_WORKSPACE:-}" '
                    split("\n") | map(select(length > 0)) |
                    map(if contains("\t") then
                            (split("\t") | {id: .[0], directory: .[1]})
                        else
                            {id: ., directory: $workspace}
                        end)
                ' <"${STUB_OPENCODE_STATE}/sessions"
            else
                printf '[]\n'
            fi
        fi
        ;;
    --standalone)
        session=
        while [ $# -gt 0 ]; do
            case "$1" in
                --session) session=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -z "$session" ] ||
            printf '%s\n' "$session" >>"${STUB_OPENCODE_STATE:?}/sessions"
        ;;
esac
STUB

cat >"${bin}/hc" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'hc %s\n' "$*" >>"${STUB_HC_LOG:?}"
case "${1:-}" in
    send | wait | label)
        ;;
    read)
        printf 'cli output\n'
        ;;
    get)
        printf '{"labels":{"task-state":"completed"}}\n'
        ;;
esac
STUB

chmod 0755 "${bin}/herdr" "${bin}/codex" "${bin}/opencode" "${bin}/hc"
mkdir -p "${tmp}/codex-state" "${tmp}/opencode-state"

export PATH="${bin}:${PATH}"
export HOME="${tmp}/home"
unset XDG_CONFIG_HOME || true
export STUB_HERDR_LOG="$herdr_log"
export STUB_HERDR_STATE="$herdr_state"
export STUB_CODEX_LOG="$codex_log"
export STUB_CODEX_STATE="${tmp}/codex-state"
export STUB_OPENCODE_LOG="$opencode_log"
export STUB_OPENCODE_STATE="${tmp}/opencode-state"
export STUB_OPENCODE_WORKSPACE="${repo_dir}"
export STUB_HC_LOG="$hc_log"
export AGENTS_TEAM_HC="${bin}/hc"
export AGENTS_TEAM_HERDR="${bin}/herdr"
export AGENTS_TEAM_DIR="${repo_dir}/team"
export AGENTS_TEAM_WORKSPACE="${repo_dir}"
export AGENTS_TEAM_WORKSPACE_ID="/host/projects/tui"
export AGENTS_TEAM_RUNTIME_DIR="$runtime"
export AGENTS_TEAM_STATE_DIR="$state"
export AGENTS_TEAM_HERDR_SESSION="test-session"
export AGENTS_TEAM_CODEX_SANDBOX="danger-full-access"
mkdir -p "$HOME"

unset AGENTS_TEAM_PLANNER_MODEL AGENTS_TEAM_IMPLEMENTER_MODEL || true

fail() {
    printf 'tui test failed: %s\n' "$*" >&2
    for file in "$herdr_log" "$codex_log" "$opencode_log" "$hc_log" "$tui_log"; do
        if [ -s "$file" ]; then
            printf '%s\n' "--- ${file} ---" >&2
            cat "$file" >&2
        fi
    done
    exit 1
}

expect_herdr() {
    grep -Fq -- "$1" "$herdr_log" ||
        fail "expected herdr command containing: $1"
}

expect_codex() {
    grep -Fq -- "$1" "$codex_log" ||
        fail "expected codex command containing: $1"
}

expect_opencode() {
    grep -Fq -- "$1" "$opencode_log" ||
        fail "expected opencode command containing: $1"
}

expect_no_codex() {
    if grep -Fq -- "$1" "$codex_log"; then
        fail "unexpected codex command containing: $1"
    fi
}

run_tui() {
    : >"$herdr_log"
    : >"$codex_log"
    : >"$opencode_log"
    : >"$hc_log"
    "${repo_dir}/team/tui.sh" "$@" 2>"$tui_log"
}

state_value() {
    jq -r --arg workspace "$AGENTS_TEAM_WORKSPACE_ID" \
        --arg role "$1" --arg key "$2" \
        '.workspaces[$workspace][$role][$key] // empty' "$state/state.json"
}

# First start: two native agents in two Herdr TUI tabs.
run_tui
expect_herdr "herdr --session test-session server"
expect_herdr "workspace create --cwd ${repo_dir} --label /host/projects/tui"
expect_herdr "tab rename w1:t1 team"
expect_herdr "pane split w1:p1 --direction right --ratio 0.5"
expect_herdr "agent start planner --kind codex --pane w1:p1"
expect_herdr "resume "
expect_herdr "agent start implementer --kind opencode --pane w1:p2"
expect_herdr "--standalone --session ses_"
expect_codex "codex exec --json"
expect_codex "--sandbox danger-full-access"

planner_session=$(state_value planner session)
implementer_session=$(state_value implementer session)
[ -n "$planner_session" ] || fail "planner session was not stored"
[ -n "$implementer_session" ] || fail "implementer session was not stored"
[ "$(state_value planner task-state)" = "unknown" ] ||
    fail "planner task state was not stored"
[ "$(state_value implementer task-state)" = "unknown" ] ||
    fail "implementer task state was not stored"
grep -Fq -- "--session test-session" "$herdr_log" ||
    fail "TUI attach did not use the named session"

cli_config="${HOME}/.config/opencode/cli.json"
jq -e '.tabs.scope == "cwd"' "$cli_config" >/dev/null ||
    fail "TUI did not create tabs.scope=cwd"

# A second start resumes both IDs without a new Codex bootstrap. It also
# preserves unrelated settings in the existing CLI config.
cat >"$cli_config" <<'JSON'
{
  "$schema": "https://opencode.ai/v2/cli.json",
  "plugins": ["file:///existing/tui-test-plugin.js"],
  "tabs": {"mode": "on", "layout": "vertical"}
}
JSON
printf '%s\n' "$implementer_session" >>"${tmp}/opencode-state/sessions"
run_tui
jq -e '
    .tabs.scope == "cwd" and
    .tabs.mode == "on" and
    .tabs.layout == "vertical" and
    .plugins == ["file:///existing/tui-test-plugin.js"]
' "$cli_config" >/dev/null ||
    fail "TUI did not set tabs.scope=cwd while preserving existing settings"
expect_herdr "agent start planner --kind codex --pane w1:p1 -- resume ${planner_session}"
expect_no_codex "codex exec"
expect_herdr "agent start implementer --kind opencode --pane w1:p2 -- --standalone --session ${implementer_session}"

# A session ID from another workspace is not resumed, even though it appears
# in the OpenCode session list.
foreign_workspace_session="ses_otherworkspace000000000"
printf '%s\t%s\n' "$foreign_workspace_session" "/host/projects/other" \
    >>"${tmp}/opencode-state/sessions"
jq --arg workspace "$AGENTS_TEAM_WORKSPACE_ID" \
    --arg session "$foreign_workspace_session" '
    .workspaces[$workspace].implementer.session = $session
' "$state/state.json" >"$state/state.json.new"
mv "$state/state.json.new" "$state/state.json"
run_tui
[ "$(state_value implementer session)" != "$foreign_workspace_session" ] ||
    fail "TUI resumed a session from another workspace"
grep -Fq "belongs to another workspace" "$tui_log" ||
    fail "TUI did not report the cross-workspace session"
if grep -Fq -- "--session ${foreign_workspace_session}" "$herdr_log"; then
    fail "TUI started OpenCode with a session from another workspace"
fi

# Fresh mode ignores saved IDs and generates new ones.
run_tui --fresh
new_planner=$(state_value planner session)
new_implementer=$(state_value implementer session)
[ "$new_planner" != "$planner_session" ] || fail "fresh reused planner session"
[ "$new_implementer" != "$implementer_session" ] ||
    fail "fresh reused implementer session"
expect_codex "codex exec --json"

# Recovered in-progress state is injected into the planner instructions.
jq --arg workspace "$AGENTS_TEAM_WORKSPACE_ID" '
    .workspaces[$workspace].planner["task-state"] = "in_progress"
' "$state/state.json" >"$state/state.json.new"
mv "$state/state.json.new" "$state/state.json"
run_tui
grep -Fq "Runtime recovery state: task-state=in_progress" \
    "${HOME}/.codex/agents-team-planner.config.toml" ||
    fail "planner profile lacks the recovery state"
grep -Fq "task state=in_progress" "$tui_log" ||
    fail "launcher did not warn about in-progress state"

# teamctl maps TUI commands and stores labels in the shared state.
(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_HERDR_SESSION=test-session
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" send implementer "hello"
) || fail "teamctl send failed"
grep -Fq "agent prompt implementer hello" "$herdr_log" ||
    fail "teamctl send did not use herdr agent prompt"

(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_HERDR_SESSION=test-session
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" wait implementer
) || fail "teamctl wait failed"
grep -Fq "agent wait implementer" "$herdr_log" ||
    fail "teamctl wait did not use herdr agent wait"

(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_HERDR_SESSION=test-session
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" read implementer --lines 12
) || fail "teamctl read failed"
grep -Fq "agent read implementer --source recent --lines 12" "$herdr_log" ||
    fail "teamctl read did not use herdr agent read"

(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_HERDR_SESSION=test-session
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" label planner task-state=completed
) || fail "teamctl label failed"
[ "$(state_value planner task-state)" = "completed" ] ||
    fail "teamctl label did not update the state file"
(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" get planner task-state
) | grep -Fxq "completed" ||
    fail "teamctl get did not read the state file"

# CLI teamctl writes the same shared state that the TUI reads.
(
    export AGENTS_TEAM_BACKEND=cli
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    export AGENTS_TEAM_WORKSPACE_ID="$AGENTS_TEAM_WORKSPACE_ID"
    "${repo_dir}/team/teamctl" label implementer task-state=in_progress
) || fail "teamctl CLI label failed"
grep -Fq "hc label implementer task-state=in_progress" "$hc_log" ||
    fail "teamctl CLI label did not use hc"
[ "$(state_value implementer task-state)" = "in_progress" ] ||
    fail "teamctl CLI label did not update shared state"
(
    export AGENTS_TEAM_BACKEND=tui
    export AGENTS_TEAM_STATE_FILE="$state/state.json"
    "${repo_dir}/team/teamctl" get implementer task-state
) | grep -Fxq "in_progress" ||
    fail "TUI did not read state written by the CLI backend"

# CLI backend keeps the herdr-core commands.
(
    export AGENTS_TEAM_BACKEND=cli
    "${repo_dir}/team/teamctl" send implementer "hello"
) || fail "teamctl CLI send failed"
grep -Fq "hc send implementer hello" "$hc_log" ||
    fail "teamctl CLI send did not use hc"

# An existing but invalid or non-object CLI config is never replaced. The TUI
# launcher fails clearly instead of discarding settings it cannot parse.
cli_config="${HOME}/.config/opencode/cli.json"
for invalid_config in '{"tabs":' '[]'; do
    printf '%s\n' "$invalid_config" >"$cli_config"
    if run_tui; then
        fail "TUI accepted an invalid CLI config"
    fi
    grep -Fq "not a valid JSON object" "$tui_log" ||
        fail "TUI did not report the invalid CLI config"
    grep -Fq "refusing to replace it" "$tui_log" ||
        fail "TUI did not refuse to replace the invalid CLI config"
    [ "$(cat "$cli_config")" = "$invalid_config" ] ||
        fail "TUI replaced an invalid CLI config"
    if grep -Fq "agent start" "$herdr_log"; then
        fail "TUI started agents with an invalid CLI config"
    fi
done

printf 'tui tests passed\n'
