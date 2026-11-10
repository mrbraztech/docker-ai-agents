#!/usr/bin/env bash
#
# agents-team TUI - start the planner/implementer team in Herdr TUI.
#
# Herdr TUI and herdr-core have separate servers. This backend runs the two
# agents as native Herdr TUI panes in one split tab, while the CLI backend keeps
# the existing herdr-core console behavior.

set -euo pipefail

TEAM_DIR="${AGENTS_TEAM_DIR:-/opt/agents-team}"
PLANNER_ROLE="${TEAM_DIR}/planner.md"
IMPLEMENTER_ROLE="${TEAM_DIR}/implementer.md"

PLANNER_NAME="planner"
IMPLEMENTER_NAME="implementer"

WORKSPACE="${AGENTS_TEAM_WORKSPACE:-/workspace}"
WORKSPACE_ID="${AGENTS_TEAM_WORKSPACE_ID:-}"
RUNTIME_DIR="${AGENTS_TEAM_RUNTIME_DIR:-${TMPDIR:-/tmp}/agents-team}"
STATE_DIR="${AGENTS_TEAM_STATE_DIR:-${HOME}/.local/state/agents-team}"
STATE_FILE="${STATE_DIR}/state.json"
LEGACY_STATE_FILE="${HOME}/.config/herdr/agents-team/state.json"

PLANNER_MODEL="${AGENTS_TEAM_PLANNER_MODEL:-}"
IMPLEMENTER_MODEL="${AGENTS_TEAM_IMPLEMENTER_MODEL:-}"
CODEX_SANDBOX_MODE="${AGENTS_TEAM_CODEX_SANDBOX:-auto}"
CODEX_SANDBOX_ARGS=()

FRESH=0
TASK_STATE_LABEL="task-state"
BOOTSTRAP_PROMPT="This is a session bootstrap. Reply with exactly READY. Do not inspect or modify any files, do not run tools, and do not start any work."

log() {
    printf 'agents-team-tui: %s\n' "$*" >&2
}

die() {
    printf 'agents-team-tui: error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

workspace_key() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -c1-16
    else
        cksum | tr ' ' '-' | cut -c1-16
    fi
}

if [ -z "$WORKSPACE_ID" ]; then
    WORKSPACE_ID=$(printf '%s' "$WORKSPACE" | workspace_key)
fi
HERDR_SESSION="${AGENTS_TEAM_HERDR_SESSION:-agents-team-$(printf '%s' "$WORKSPACE_ID" | workspace_key)}"
export AGENTS_TEAM_BACKEND=tui
export AGENTS_TEAM_HERDR_SESSION="$HERDR_SESSION"
export AGENTS_TEAM_WORKSPACE_ID="$WORKSPACE_ID"
export AGENTS_TEAM_WORKSPACE="$WORKSPACE"
export AGENTS_TEAM_STATE_FILE="$STATE_FILE"

herdr_cmd() {
    command herdr --session "$HERDR_SESSION" "$@"
}

configure_codex_sandbox() {
    case "$CODEX_SANDBOX_MODE" in
        auto)
            if command -v bwrap >/dev/null 2>&1 &&
                bwrap --unshare-user --dev-bind / / true >/dev/null 2>&1; then
                CODEX_SANDBOX_ARGS=()
            else
                log "Codex sandbox unavailable (bubblewrap user namespaces blocked); using danger-full-access inside the container"
                CODEX_SANDBOX_ARGS=(--sandbox danger-full-access)
            fi
            ;;
        default)
            CODEX_SANDBOX_ARGS=()
            ;;
        read-only | workspace-write | danger-full-access)
            CODEX_SANDBOX_ARGS=(--sandbox "$CODEX_SANDBOX_MODE")
            ;;
        *)
            die "unknown Codex sandbox mode: ${CODEX_SANDBOX_MODE}"
            ;;
    esac
}

state_default() {
    printf '%s' '{"version":1,"workspaces":{}}'
}

read_state() {
    if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_STATE_FILE" ] &&
        jq -e 'type == "object"' "$LEGACY_STATE_FILE" >/dev/null 2>&1; then
        mkdir -p "$STATE_DIR"
        cp "$LEGACY_STATE_FILE" "$STATE_FILE"
        log "migrated legacy TUI state into ${STATE_FILE}"
    fi
    [ -f "$STATE_FILE" ] || {
        state_default
        return 0
    }
    if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
        log "state file is corrupt; starting fresh (${STATE_FILE})"
        state_default
        return 0
    fi
    cat "$STATE_FILE"
}

write_state() {
    local content=$1 directory temporary
    directory=$(dirname "$STATE_FILE")
    mkdir -p "$directory"
    temporary=$(mktemp "${STATE_FILE}.XXXXXX")
    printf '%s\n' "$content" >"$temporary"
    mv -f "$temporary" "$STATE_FILE"
}

state_get() {
    local role=$1 key=$2
    read_state | jq -r --arg workspace "$WORKSPACE_ID" --arg role "$role" \
        --arg key "$key" '.workspaces[$workspace][$role][$key] // empty'
}

state_set() {
    local role=$1 key=$2 value=$3 content
    content=$(read_state | jq -c \
        --arg workspace "$WORKSPACE_ID" --arg role "$role" \
        --arg key "$key" --arg value "$value" '
        .version = (.version // 1) |
        .workspaces = (.workspaces // {}) |
        .workspaces[$workspace] = (.workspaces[$workspace] // {}) |
        .workspaces[$workspace][$role] =
            ((.workspaces[$workspace][$role] // {}) + {($key): $value})
        ')
    write_state "$content"
}

recovery_note() {
    local state=$1

    cat <<EOF
Runtime recovery state: task-state=${state}.
If this state is in_progress or unknown, do not continue implementation
automatically. Inspect the repository and conversation history, report what is
confirmed and what is uncertain, and ask the user for explicit confirmation
before proceeding. Never replay the previous task prompt and never treat
restored history as task success.
EOF
}

write_codex_profile() {
    local state=$1 path instructions temporary
    path="${CODEX_HOME:-${HOME}/.codex}/agents-team-planner.config.toml"

    instructions=$(
        {
            cat "$PLANNER_ROLE"
            printf '\n\n'
            recovery_note "$state"
        } | jq -Rs .
    )
    mkdir -p "$(dirname "$path")"
    temporary=$(mktemp "${path}.XXXXXX")
    printf 'developer_instructions = %s\n' "$instructions" >"$temporary"
    mv -f "$temporary" "$path"
}

valid_session() {
    local agent=$1 session=$2
    [ -n "$session" ] || return 1
    case "$agent" in
        codex)
            printf '%s' "$session" |
                grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            ;;
        opencode)
            printf '%s' "$session" | grep -Eq '^ses_[A-Za-z0-9]+$'
            ;;
        *)
            return 1
            ;;
    esac
}

new_opencode_session() {
    printf 'ses_%s' "$(od -An -N13 -tx1 /dev/urandom | tr -d ' \n')"
}

opencode_session_exists() {
    local session=$1 output
    if ! output=$(cd "$WORKSPACE" &&
        opencode session list --format json -n 1000 2>/dev/null); then
        return 1
    fi
    printf '%s' "$output" |
        jq -e --arg session "$session" 'any(.[]; .id == $session)' \
            >/dev/null 2>&1
}

bootstrap_codex_session() {
    local instructions output thread_id completed
    local -a bootstrap_args
    local bootstrap_error="${RUNTIME_DIR}/bootstrap-codex.err"

    instructions=$(jq -Rs . <"$PLANNER_ROLE")
    bootstrap_args=(
        codex
        exec
        --json
        -C "$WORKSPACE"
        --skip-git-repo-check
        "${CODEX_SANDBOX_ARGS[@]}"
        -c "developer_instructions=${instructions}"
    )
    if [ -n "$PLANNER_MODEL" ]; then
        bootstrap_args+=(-m "$PLANNER_MODEL")
    fi
    bootstrap_args+=("$BOOTSTRAP_PROMPT")

    log "creating a new planner session (neutral Codex bootstrap)"
    if ! output=$(timeout 120 "${bootstrap_args[@]}" \
        </dev/null 2>"$bootstrap_error"); then
        log "Codex bootstrap failed"
        [ -s "$bootstrap_error" ] && cat "$bootstrap_error" >&2
        return 1
    fi

    thread_id=$(printf '%s\n' "$output" |
        jq -r 'select(.type == "thread.started") | .thread_id // empty' \
            2>/dev/null | head -n 1)
    completed=$(printf '%s\n' "$output" |
        jq -r 'select(.type == "turn.completed") | .type' 2>/dev/null |
        head -n 1)

    if ! valid_session codex "$thread_id" || [ -z "$completed" ]; then
        log "Codex bootstrap did not return a complete, resumable session"
        return 1
    fi
    log "created Codex session ${thread_id} (thread.started + turn.completed)"
    printf '%s' "$thread_id"
}

write_opencode_config() {
    local path=$1 role_file=$2 model=$3
    mkdir -p "$(dirname "$path")"
    jq -n \
        --arg schema "https://opencode.ai/config.json" \
        --arg role "$role_file" \
        --arg model "$model" \
        '{ "$schema": $schema, instructions: [$role] }
         + (if $model == "" then {} else { model: $model } end)' \
        >"$path"
}

cleanup() {
    local status=$?
    herdr session stop "$HERDR_SESSION" >/dev/null 2>&1 || true
    exit "$status"
}

wait_for_server() {
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if herdr --session "$HERDR_SESSION" status 2>/dev/null |
            grep -q 'status: running'; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return 1
}

main() {
    local implementer_session planner_session implementer_task planner_task
    local workspace_json workspace_id planner_pane planner_tab
    local implementer_json implementer_pane instructions
    local -a codex_args
    local -a team_env

    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH=1
                shift
                ;;
            --tui | --cli)
                shift
                ;;
            *)
                die "unknown team option: $1"
                ;;
        esac
    done

    require_command herdr
    require_command jq
    require_command codex
    require_command opencode
    require_command timeout
    require_command od

    [ -r "$PLANNER_ROLE" ] || die "planner role file not found: $PLANNER_ROLE"
    [ -r "$IMPLEMENTER_ROLE" ] || die "implementer role file not found: $IMPLEMENTER_ROLE"

    configure_codex_sandbox
    mkdir -p "$RUNTIME_DIR" "$STATE_DIR"
    write_opencode_config "${RUNTIME_DIR}/opencode.json" \
        "$IMPLEMENTER_ROLE" "$IMPLEMENTER_MODEL"

    implementer_session=$(state_get implementer session)
    planner_session=$(state_get planner session)
    implementer_task=$(state_get implementer "$TASK_STATE_LABEL")
    planner_task=$(state_get planner "$TASK_STATE_LABEL")
    [ -n "$implementer_task" ] || implementer_task="unknown"
    [ -n "$planner_task" ] || planner_task="unknown"

    if [ "$FRESH" -eq 1 ]; then
        log "fresh mode: ignoring saved team sessions"
        implementer_session=""
        planner_session=""
        implementer_task="unknown"
        planner_task="unknown"
    fi

    if [ -n "$implementer_session" ] &&
        ! opencode_session_exists "$implementer_session"; then
        log "saved implementer session is not available; starting a new conversation"
        implementer_session=""
        implementer_task="unknown"
    fi
    if [ -n "$planner_session" ] &&
        ! valid_session codex "$planner_session"; then
        log "saved planner session is invalid; starting a new conversation"
        planner_session=""
        planner_task="unknown"
    fi

    [ -n "$implementer_session" ] ||
        implementer_session=$(new_opencode_session)
    [ -n "$planner_session" ] ||
        planner_session=$(bootstrap_codex_session) ||
        die "could not create a new planner session"

    write_codex_profile "$planner_task"
    [ "$planner_task" = "completed" ] ||
        log "planner task state=${planner_task}: inspect the repository and history, then ask for explicit confirmation before continuing"
    [ "$implementer_task" = "completed" ] ||
        log "implementer task state=${implementer_task}: inspect the repository and history, then ask for explicit confirmation before continuing"

    herdr session stop "$HERDR_SESSION" >/dev/null 2>&1 || true
    herdr session delete "$HERDR_SESSION" >/dev/null 2>&1 || true
    herdr --session "$HERDR_SESSION" server \
        >"${RUNTIME_DIR}/herdr-tui-server.log" 2>&1 &
    trap cleanup EXIT

    wait_for_server ||
        die "Herdr TUI server did not start; see ${RUNTIME_DIR}/herdr-tui-server.log"

    team_env=(
        --env "AGENTS_TEAM_BACKEND=tui"
        --env "AGENTS_TEAM_WORKSPACE_ID=${WORKSPACE_ID}"
        --env "AGENTS_TEAM_HERDR_SESSION=${HERDR_SESSION}"
        --env "AGENTS_TEAM_STATE_FILE=${STATE_FILE}"
    )

    workspace_json=$(herdr_cmd workspace create \
        --cwd "$WORKSPACE" --label "$WORKSPACE_ID" \
        "${team_env[@]}" --no-focus) ||
        die "could not create the Herdr TUI workspace"
    workspace_id=$(printf '%s' "$workspace_json" |
        jq -r '.result.workspace.workspace_id // empty')
    planner_pane=$(printf '%s' "$workspace_json" |
        jq -r '.result.root_pane.pane_id // empty')
    planner_tab=$(printf '%s' "$workspace_json" |
        jq -r '.result.tab.tab_id // empty')
    [ -n "$workspace_id" ] && [ -n "$planner_pane" ] && [ -n "$planner_tab" ] ||
        die "could not read the new Herdr TUI workspace"

    herdr_cmd tab rename "$planner_tab" team >/dev/null ||
        die "could not name the team tab"

    implementer_json=$(herdr_cmd pane split "$planner_pane" \
        --direction right --ratio 0.5 \
        --cwd "$WORKSPACE" \
        "${team_env[@]}" \
        --env "OPENCODE_CONFIG=${RUNTIME_DIR}/opencode.json" \
        --no-focus) ||
        die "could not split the implementer pane"
    implementer_pane=$(printf '%s' "$implementer_json" |
        jq -r '.result.pane.pane_id // empty')
    [ -n "$implementer_pane" ] ||
        die "could not read the implementer pane"

    codex_args=(
        resume "$planner_session"
        --no-daemon
        -C "$WORKSPACE"
        "${CODEX_SANDBOX_ARGS[@]}"
        -p agents-team-planner
    )
    [ -z "$PLANNER_MODEL" ] || codex_args+=(-m "$PLANNER_MODEL")

    state_set planner session "$planner_session"
    state_set planner "$TASK_STATE_LABEL" "$planner_task"
    state_set implementer session "$implementer_session"
    state_set implementer "$TASK_STATE_LABEL" "$implementer_task"

    log "starting planner (Codex) in Herdr TUI pane"
    herdr_cmd agent start "$PLANNER_NAME" --kind codex \
        --pane "$planner_pane" -- "${codex_args[@]}" >/dev/null ||
        die "could not start the planner agent"

    log "starting implementer (OpenCode) in Herdr TUI pane"
    herdr_cmd agent start "$IMPLEMENTER_NAME" --kind opencode \
        --pane "$implementer_pane" -- \
        --standalone --session "$implementer_session" >/dev/null ||
        die "could not start the implementer agent"

    log "attaching to Herdr TUI; switch panes with ctrl+b h/l, detach with ctrl+b q"
    herdr --session "$HERDR_SESSION"
}

main "$@"
