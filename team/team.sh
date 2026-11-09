#!/usr/bin/env bash
#
# agents-team - start or reattach the planner/implementer team.
#
# This script runs inside the workspace container. It uses one Herdr Core
# instance for both roles and reuses live terminals with the same names.
# Finished terminals are kept until a replacement terminal has confirmed the
# same workspace/role/session association, then removed.

set -euo pipefail

TEAM_DIR="${AGENTS_TEAM_DIR:-/opt/agents-team}"
PLANNER_ROLE="${TEAM_DIR}/planner.md"
IMPLEMENTER_ROLE="${TEAM_DIR}/implementer.md"

PLANNER_NAME="planner"
IMPLEMENTER_NAME="implementer"

WORKSPACE="${AGENTS_TEAM_WORKSPACE:-/workspace}"
WORKSPACE_ID="${AGENTS_TEAM_WORKSPACE_ID:-}"
RUNTIME_DIR="${AGENTS_TEAM_RUNTIME_DIR:-${TMPDIR:-/tmp}/agents-team}"

PLANNER_MODEL="${AGENTS_TEAM_PLANNER_MODEL:-}"
IMPLEMENTER_MODEL="${AGENTS_TEAM_IMPLEMENTER_MODEL:-}"

FRESH=0
TASK_STATE_LABEL="task-state"
BOOTSTRAP_PROMPT="This is a session bootstrap. Reply with exactly READY. Do not inspect or modify any files, do not run tools, and do not start any work."

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

record_field() {
    local output=$1 field=$2 value

    value=$(printf '%s' "$output" | jq -r --arg field "$field" '
        if type == "object" then .[$field] // empty else empty end
        | if type == "string" or type == "number" then tostring else empty end' \
        2>/dev/null) || value=""

    printf '%s' "$value"
}

label_value() {
    local output=$1 key=$2 value

    value=$(printf '%s' "$output" | jq -r --arg key "$key" '
        if type == "object" and (.labels | type) == "object"
        then .labels[$key] // empty else empty end' 2>/dev/null) || value=""

    printf '%s' "$value"
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

task_state_of() {
    local output=$1 state

    state=$(label_value "$output" "$TASK_STATE_LABEL")
    case "$state" in
        in_progress | completed)
            ;;
        *)
            state="unknown"
            ;;
    esac

    printf '%s' "$state"
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

candidate_session() {
    local role=$1 agent=$2 output=$3
    local recorded_role recorded_workspace session

    [ -n "$output" ] || return 0
    [ -n "$WORKSPACE_ID" ] || return 0

    recorded_role=$(label_value "$output" role)
    recorded_workspace=$(label_value "$output" workspace)
    session=$(label_value "$output" session)

    [ "$recorded_role" = "$role" ] || return 0
    [ "$recorded_workspace" = "$WORKSPACE_ID" ] || return 0
    valid_session "$agent" "$session" || return 0

    printf '%s' "$session"
}

distinct_saved_sessions() {
    local name=$1 role=$2 output

    if ! output=$(hc ls --all --json 2>/dev/null); then
        return 1
    fi

    printf '%s' "$output" | jq -r --arg name "$name" --arg role "$role" \
        --arg workspace "$WORKSPACE_ID" '
        [.terminals[]? | select(.name == $name) |
         select((.labels.role // "") == $role) |
         select($workspace == "" or (.labels.workspace // "") == $workspace) |
         (.labels.session // empty) | select(length > 0)] |
        unique | length' 2>/dev/null | head -n 1
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

    # Codex stores a session only after a turn. This fixed prompt creates the
    # conversation without inspecting the workspace or starting any work.
    instructions=$(jq -Rs . <"$PLANNER_ROLE")

    bootstrap_args=(
        codex
        exec
        --json
        -C "$WORKSPACE"
        --skip-git-repo-check
        --sandbox read-only
        -c "developer_instructions=${instructions}"
    )

    if [ -n "$PLANNER_MODEL" ]; then
        bootstrap_args+=(-m "$PLANNER_MODEL")
    fi

    bootstrap_args+=("$BOOTSTRAP_PROMPT")

    log "creating a new ${PLANNER_NAME} session (neutral Codex bootstrap)"
    if ! output=$(timeout 120 "${bootstrap_args[@]}" \
        </dev/null 2>"$bootstrap_error"); then
        log "Codex bootstrap failed"
        if [ -s "$bootstrap_error" ]; then
            cat "$bootstrap_error" >&2
        fi
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

    # thread.started identifies the exact session. turn.completed confirms the
    # turn finished, which is when Codex records the session. No extra turn or
    # TTY-only probe is used as persistence evidence.
    log "created Codex session ${thread_id} (thread.started + turn.completed)"

    printf '%s' "$thread_id"
}

role_labels() {
    local role=$1 session=$2 task_state=$3

    printf '%s\n' "team=agents" "role=${role}" "session=${session}" \
        "${TASK_STATE_LABEL}=${task_state}"

    if [ -n "$WORKSPACE_ID" ]; then
        printf '%s\n' "workspace=${WORKSPACE_ID}"
    fi
}

build_label_args() {
    local role=$1 session=$2 task_state=$3 label
    local -a labels

    mapfile -t labels < <(role_labels "$role" "$session" "$task_state")
    for label in "${labels[@]}"; do
        printf '%s\0' --label "$label"
    done
}

start_implementer() {
    local session=$1 task_state=$2 output
    local config="${RUNTIME_DIR}/opencode.json"
    local -a labels

    write_opencode_config "$config" "$IMPLEMENTER_ROLE" "$IMPLEMENTER_MODEL"
    mapfile -d '' -t labels < <(build_label_args implementer "$session" "$task_state")

    # Use a private OpenCode server so the team container does not race with
    # other containers over the shared service registration.
    log "starting ${IMPLEMENTER_NAME} (OpenCode) with session ${session}"
    if ! output=$(hc run \
        --bg \
        --name "$IMPLEMENTER_NAME" \
        --cwd "$WORKSPACE" \
        "${labels[@]}" \
        --no-parent \
        --outlive-parent \
        -- env OPENCODE_CONFIG="$config" opencode --standalone \
        --session "$session"); then
        log "could not start ${IMPLEMENTER_NAME}"
        return 1
    fi

    printf '%s\n' "$output"
}

start_planner() {
    local session=$1 task_state=$2 output instructions
    local -a labels planner_args

    # Codex reads this configuration value as additional developer
    # instructions. Passing it as a TOML string preserves the file's line
    # breaks without replacing Codex's own base instructions. The recovery
    # note states the current delegation state in the conversation itself,
    # not only in the launcher log.
    instructions=$(
        {
            cat "$PLANNER_ROLE"
            printf '\n\n'
            recovery_note "$task_state"
        } | jq -Rs .
    )
    mapfile -d '' -t labels < <(build_label_args planner "$session" "$task_state")

    planner_args=(
        codex
        resume "$session"
        # Herdr needs Codex without its background daemon so Codex's shell
        # commands run inside the Herdr terminal.
        --no-daemon
        -C "$WORKSPACE"
        -c "developer_instructions=${instructions}"
    )

    if [ -n "$PLANNER_MODEL" ]; then
        planner_args+=(-m "$PLANNER_MODEL")
    fi

    log "starting ${PLANNER_NAME} (Codex) with session ${session}"
    if ! output=$(hc run \
        --bg \
        --name "$PLANNER_NAME" \
        --cwd "$WORKSPACE" \
        "${labels[@]}" \
        --no-parent \
        --outlive-parent \
        -- "${planner_args[@]}"); then
        log "could not start ${PLANNER_NAME}"
        return 1
    fi

    printf '%s\n' "$output"
}

start_for_role() {
    local role=$1 session=$2 task_state=$3

    case "$role" in
        implementer)
            start_implementer "$session" "$task_state"
            ;;
        planner)
            start_planner "$session" "$task_state"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_live() {
    local target=$1 label=${2:-$1} state

    state=$(terminal_state "$target")
    case "$state" in
        live)
            ;;
        unknown)
            log "terminal ${label} reported unknown state; keeping it"
            ;;
        *)
            log "terminal ${label} is ${state}; showing its last screen"
            hc read "$label" --lines 40 >&2 || true
            return 1
            ;;
    esac
}

apply_association_labels() {
    local address=$1 role=$2 session=$3 task_state=$4
    local -a labels

    mapfile -t labels < <(role_labels "$role" "$session" "$task_state")
    hc label "$address" "${labels[@]}" >/dev/null
}

verify_association() {
    local address=$1 role=$2 session=$3 task_state=$4 output

    output=$(hc get "$address" --json 2>/dev/null) || return 1

    [ "$(label_value "$output" role)" = "$role" ] || return 1
    [ "$(label_value "$output" session)" = "$session" ] || return 1
    [ "$(label_value "$output" "$TASK_STATE_LABEL")" = "$task_state" ] ||
        return 1

    if [ -n "$WORKSPACE_ID" ]; then
        [ "$(label_value "$output" workspace)" = "$WORKSPACE_ID" ] ||
            return 1
    fi

    return 0
}

cleanup_failed_start() {
    local address=$1 old_address=$2 state

    [ -n "$address" ] || return 0
    [ "$address" = "$old_address" ] && return 0

    state=$(terminal_state "$address")
    if [ "$state" = "live" ]; then
        hc kill "$address" >/dev/null 2>&1 || true
    fi
    hc rm "$address" >/dev/null 2>&1 || true
}

remove_previous_records() {
    local name=$1 role=$2 new_address=$3 output addresses
    local address

    if ! output=$(hc ls --all --json 2>/dev/null); then
        log "could not list previous ${role} records; skipping cleanup and keeping them"
        return 0
    fi

    addresses=$(printf '%s' "$output" | jq -r \
        --arg name "$name" --arg role "$role" \
        --arg workspace "$WORKSPACE_ID" --arg new "$new_address" '
        .terminals[]? |
        select(.name == $name and .state == "finished") |
        select(.address != $new) |
        select((.labels.role // "") == $role) |
        select($workspace == "" or (.labels.workspace // "") == $workspace) |
        .address' 2>/dev/null)

    for address in $addresses; do
        log "removing previous ${role} terminal ${address}"
        hc rm "$address" >/dev/null || log "could not remove ${address}"
    done
}

ensure_role() {
    local name=$1 role=$2 agent=$3 candidate=$4 old_output=$5
    local state old_address task_state session output address resumed=0
    local old_workspace live_role live_workspace unknown_role unknown_workspace

    state=$(terminal_state "$name")

    case "$state" in
        live)
            live_role=$(label_value "$old_output" role)
            live_workspace=$(label_value "$old_output" workspace)

            if [ -z "$WORKSPACE_ID" ] ||
                [ "$live_role" != "$role" ] ||
                [ "$live_workspace" != "$WORKSPACE_ID" ]; then
                die "live ${name} terminal belongs to role '${live_role:-unknown}' and workspace '${live_workspace:-unknown}', not role '${role}' and workspace '${WORKSPACE_ID:-unknown}'; refusing to attach to or modify it"
            fi

            if [ "$FRESH" -eq 1 ]; then
                log "fresh mode: keeping live ${name} terminal; it was not restarted"
            else
                log "reusing live ${name} terminal"
            fi
            return 0
            ;;
        unknown)
            unknown_role=$(label_value "$old_output" role)
            unknown_workspace=$(label_value "$old_output" workspace)

            if [ -z "$WORKSPACE_ID" ] ||
                [ "$unknown_role" != "$role" ] ||
                [ "$unknown_workspace" != "$WORKSPACE_ID" ]; then
                die "terminal ${name} state is unknown and its role/workspace labels could not be validated; refusing to attach to or modify it"
            fi

            log "reusing ${name} terminal with unknown state"
            return 0
            ;;
    esac

    old_address=$(record_field "$old_output" address)
    task_state=$(task_state_of "$old_output")
    [ -n "$old_output" ] || task_state="unknown"

    if [ -n "$old_output" ] && [ -n "$WORKSPACE_ID" ]; then
        old_workspace=$(label_value "$old_output" workspace)
        if [ "$old_workspace" != "$WORKSPACE_ID" ]; then
            log "ignoring ${name} association from another workspace"
        fi
    fi

    if [ "$FRESH" -eq 1 ]; then
        log "fresh mode: ignoring saved ${role} session"
        candidate=""
    fi

    if [ -n "$candidate" ]; then
        case "$agent" in
            opencode)
                if ! opencode_session_exists "$candidate"; then
                    log "saved ${role} OpenCode session ${candidate} is not available; starting a new conversation"
                    candidate=""
                fi
                ;;
        esac
    fi

    if [ -n "$candidate" ]; then
        session=$candidate
        resumed=1
        log "resuming ${role} session ${session}"
    else
        if [ "$agent" = "codex" ]; then
            session=$(bootstrap_codex_session) ||
                die "could not create a new ${role} session"
        else
            session=$(new_opencode_session)
        fi
        task_state="unknown"
        log "starting a new ${role} session ${session}"
    fi

    if [ "$state" = "finished" ]; then
        log "keeping finished ${name} terminal ${old_address} until the new association is confirmed"
    fi

    if ! output=$(start_for_role "$role" "$session" "$task_state"); then
        if [ "$resumed" -eq 1 ]; then
            die "saved ${role} session ${session} could not be resumed; run 'agents team --fresh' to start a new conversation"
        fi
        die "could not start the ${name} terminal"
    fi

    address=$(printf '%s' "$output" | jq -r '.address // empty' 2>/dev/null) ||
        address=""
    if [ -z "$address" ]; then
        address=$(record_field "$(hc get "$name" --json 2>/dev/null || true)" address)
    fi
    [ -n "$address" ] || die "could not identify the new ${name} terminal"

    # A Codex TUI that cannot load a saved session exits after printing its
    # error. Give it a moment so a broken saved ID fails clearly instead of
    # being accepted as a live terminal.
    if [ "$resumed" -eq 1 ] && [ "$agent" = "codex" ]; then
        sleep 1
    fi

    if ! verify_live "$address" "$name"; then
        cleanup_failed_start "$address" "$old_address"
        if [ "$resumed" -eq 1 ]; then
            die "saved ${role} session ${session} could not be resumed; run 'agents team --fresh' to start a new conversation"
        fi
        die "could not start the ${name} terminal"
    fi

    if ! verify_association "$address" "$role" "$session" "$task_state"; then
        log "association labels were not confirmed on ${name}; repairing"
        if ! apply_association_labels "$address" "$role" "$session" \
            "$task_state" ||
            ! verify_association "$address" "$role" "$session" "$task_state"; then
            cleanup_failed_start "$address" "$old_address"
            die "could not confirm the ${name} session association"
        fi
    fi

    if [ "$task_state" != "completed" ]; then
        log "${name} task state=${task_state}: inspect the repository and conversation history, report uncertainty, and ask the user for explicit confirmation before continuing implementation"
    fi

    if [ "$resumed" -eq 1 ] && [ -n "$old_address" ] &&
        [ "$old_address" != "$address" ]; then
        # There is no non-mutative signal that proves the saved native
        # conversation was loaded. Keep the previous record instead of
        # claiming a transfer that was not observed.
        log "keeping previous ${role} terminal ${old_address}: saved ${agent} session load is not confirmed"
    else
        remove_previous_records "$name" "$role" "$address"
    fi
}

main() {
    local implementer_output planner_output
    local implementer_candidate planner_candidate
    local implementer_sessions planner_sessions

    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH=1
                shift
                ;;
            *)
                die "unknown team option: $1"
                ;;
        esac
    done

    require_command hc
    require_command jq
    require_command codex
    require_command opencode
    require_command timeout
    require_command od

    [ -r "$PLANNER_ROLE" ] || die "planner role file not found: $PLANNER_ROLE"
    [ -r "$IMPLEMENTER_ROLE" ] || die "implementer role file not found: $IMPLEMENTER_ROLE"

    if [ -z "$WORKSPACE_ID" ]; then
        log "workspace identity is unavailable; saved conversations will not be reused"
    fi

    hc server start >/dev/null
    mkdir -p "$RUNTIME_DIR"

    implementer_output=$(hc get "$IMPLEMENTER_NAME" --json 2>/dev/null || true)
    planner_output=$(hc get "$PLANNER_NAME" --json 2>/dev/null || true)

    implementer_candidate=$(candidate_session implementer opencode "$implementer_output")
    planner_candidate=$(candidate_session planner codex "$planner_output")

    if ! implementer_sessions=$(distinct_saved_sessions "$IMPLEMENTER_NAME" implementer); then
        log "could not inspect saved ${IMPLEMENTER_NAME} sessions; starting a new conversation"
        implementer_candidate=""
        implementer_sessions=0
    fi
    if ! planner_sessions=$(distinct_saved_sessions "$PLANNER_NAME" planner); then
        log "could not inspect saved ${PLANNER_NAME} sessions; starting a new conversation"
        planner_candidate=""
        planner_sessions=0
    fi

    if [ -n "$implementer_sessions" ] && [ "$implementer_sessions" -gt 1 ]; then
        log "ambiguous session association for ${IMPLEMENTER_NAME}; starting a new conversation"
        implementer_candidate=""
    fi
    if [ -n "$planner_sessions" ] && [ "$planner_sessions" -gt 1 ]; then
        log "ambiguous session association for ${PLANNER_NAME}; starting a new conversation"
        planner_candidate=""
    fi

    if [ -n "$implementer_candidate" ] &&
        [ "$implementer_candidate" = "$planner_candidate" ]; then
        log "ambiguous session association: both roles reference ${implementer_candidate}; starting new conversations"
        implementer_candidate=""
        planner_candidate=""
    fi

    ensure_role "$IMPLEMENTER_NAME" implementer opencode \
        "$implementer_candidate" "$implementer_output"
    ensure_role "$PLANNER_NAME" planner codex \
        "$planner_candidate" "$planner_output"

    report_status

    log "attaching to ${PLANNER_NAME}; detach with ctrl+\\"
    hc attach "$PLANNER_NAME"
}

main "$@"
