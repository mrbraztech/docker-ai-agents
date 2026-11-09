#!/usr/bin/env bash
#
# agents-team - start or reattach the planner/implementer team.
#
# This script runs inside the workspace container. It uses one Herdr Core
# instance for both roles and reuses live terminals with the same names.
# Finished terminals are removed before a role is started again.

set -euo pipefail

TEAM_DIR="${AGENTS_TEAM_DIR:-/opt/agents-team}"
PLANNER_ROLE="${TEAM_DIR}/planner.md"
IMPLEMENTER_ROLE="${TEAM_DIR}/implementer.md"

PLANNER_NAME="planner"
IMPLEMENTER_NAME="implementer"

WORKSPACE="${AGENTS_TEAM_WORKSPACE:-/workspace}"
RUNTIME_DIR="${AGENTS_TEAM_RUNTIME_DIR:-${TMPDIR:-/tmp}/agents-team}"

PLANNER_MODEL="${AGENTS_TEAM_PLANNER_MODEL:-}"
IMPLEMENTER_MODEL="${AGENTS_TEAM_IMPLEMENTER_MODEL:-}"

log() {
    printf 'agents-team: %s\n' "$*" >&2
}

die() {
    printf 'agents-team: error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

json_field() {
    local output=$1 field=$2 value

    # Missing, malformed, or unexpected fields must never stop the launcher.
    value=$(printf '%s' "$output" | jq -r --arg field "$field" '
        if type == "object" then
            (.[$field] // "unknown")
        else
            "unknown"
        end
        | if type == "string" or type == "number" or type == "boolean"
          then tostring else "unknown" end' 2>/dev/null) || value="unknown"

    printf '%s' "${value:-unknown}"
}

terminal_state() {
    local name=$1 output state

    if output=$(hc get "$name" --json 2>/dev/null); then
        state=$(json_field "$output" state)
        case "$state" in
            live | finished)
                ;;
            *)
                state="unknown"
                ;;
        esac
        printf '%s' "$state"
        return 0
    fi

    printf 'missing'
}

report_status() {
    local name output state status

    for name in "$IMPLEMENTER_NAME" "$PLANNER_NAME"; do
        if output=$(hc get "$name" --json 2>/dev/null); then
            state=$(json_field "$output" state)
            status=$(json_field "$output" status)
        else
            state="missing"
            status="unknown"
        fi

        log "${name}: state=${state} status=${status}"
    done
}

remove_finished_terminal() {
    local name=$1 state

    state=$(terminal_state "$name")
    case "$state" in
        live)
            log "reusing live ${name} terminal"
            return 1
            ;;
        finished)
            log "removing finished ${name} terminal"
            hc rm "$name" >/dev/null
            ;;
        unknown)
            log "reusing ${name} terminal with unknown state"
            return 1
            ;;
    esac

    return 0
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

start_implementer() {
    local config="${RUNTIME_DIR}/opencode.json"

    write_opencode_config "$config" "$IMPLEMENTER_ROLE" "$IMPLEMENTER_MODEL"

    # Use a private OpenCode server so the team container does not race with
    # other containers over the shared service registration.
    log "starting ${IMPLEMENTER_NAME} (OpenCode)"
    hc run \
        --bg \
        --name "$IMPLEMENTER_NAME" \
        --cwd "$WORKSPACE" \
        --label team=agents \
        --label role=implementer \
        --no-parent \
        --outlive-parent \
        -- env OPENCODE_CONFIG="$config" opencode --standalone
}

start_planner() {
    local instructions
    local -a planner_args

    # Codex reads this configuration value as additional developer
    # instructions. Passing it as a TOML string preserves the file's line
    # breaks without replacing Codex's own base instructions.
    instructions=$(jq -Rs . <"$PLANNER_ROLE")

    planner_args=(
        codex
        # Herdr needs Codex without its background daemon so Codex's shell
        # commands run inside the Herdr terminal.
        --no-daemon
        -C "$WORKSPACE"
        -c "developer_instructions=${instructions}"
    )

    if [ -n "$PLANNER_MODEL" ]; then
        planner_args+=(-m "$PLANNER_MODEL")
    fi

    log "starting ${PLANNER_NAME} (Codex)"
    hc run \
        --bg \
        --name "$PLANNER_NAME" \
        --cwd "$WORKSPACE" \
        --label team=agents \
        --label role=planner \
        --no-parent \
        --outlive-parent \
        -- "${planner_args[@]}"
}

ensure_role() {
    local name=$1
    shift

    if remove_finished_terminal "$name"; then
        "$@"
    fi
}

verify_live() {
    local name=$1 state

    state=$(terminal_state "$name")
    case "$state" in
        live)
            ;;
        unknown)
            log "terminal ${name} reported unknown state; keeping it"
            ;;
        *)
            log "terminal ${name} is ${state}; showing its last screen"
            hc read "$name" --lines 40 >&2 || true
            die "could not start the ${name} terminal"
            ;;
    esac
}

main() {
    require_command hc
    require_command jq
    require_command codex
    require_command opencode

    [ -r "$PLANNER_ROLE" ] || die "planner role file not found: $PLANNER_ROLE"
    [ -r "$IMPLEMENTER_ROLE" ] || die "implementer role file not found: $IMPLEMENTER_ROLE"

    hc server start >/dev/null
    mkdir -p "$RUNTIME_DIR"

    ensure_role "$IMPLEMENTER_NAME" start_implementer
    verify_live "$IMPLEMENTER_NAME"

    ensure_role "$PLANNER_NAME" start_planner
    verify_live "$PLANNER_NAME"

    report_status

    log "attaching to ${PLANNER_NAME}; detach with ctrl+\\"
    hc attach "$PLANNER_NAME"
}

main "$@"
