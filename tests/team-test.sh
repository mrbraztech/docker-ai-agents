#!/usr/bin/env bash
#
# Team launcher tests with stub hc, codex, and opencode. They exercise native
# session continuity, live-session reuse, fresh starts, association transfer,
# and interrupted-task safeguards without starting a real container or Herdr
# Core.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin="${tmp}/bin"
state="${tmp}/state"
runtime="${tmp}/runtime"
log="${tmp}/hc.log"
codex_log="${tmp}/codex.log"
opencode_log="${tmp}/opencode.log"
team_log="${tmp}/team.log"

mkdir -p "$bin" "$state" "$runtime"

cat >"${bin}/hc" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'hc %s\n' "$*" >>"${STUB_HC_LOG:?}"

state_dir="${STUB_HC_STATE:?}"
command_name=${1:-}
shift || true

index_for() {
    printf '%s/.name-%s' "$state_dir" "$1"
}

resolve_terminal() {
    local arg=$1 index address best best_number number

    if [ -f "${state_dir}/${arg}.json" ]; then
        printf '%s/%s.json' "$state_dir" "$arg"
        return 0
    fi

    index=$(index_for "$arg")
    if [ -f "$index" ]; then
        address=$(cat "$index")
        if [ -f "${state_dir}/${address}.json" ]; then
            printf '%s/%s.json' "$state_dir" "$address"
            return 0
        fi
    fi

    best=
    best_number=-1
    for file in "${state_dir}"/t*.json; do
        [ -f "$file" ] || continue
        [ "$(jq -r '.name // empty' "$file")" = "$arg" ] || continue
        address=$(basename "$file" .json)
        number=${address#t}
        case "$number" in
            '' | *[!0-9]*) number=0 ;;
        esac
        if [ "$number" -gt "$best_number" ]; then
            best=$file
            best_number=$number
        fi
    done

    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

refresh_index() {
    local name=$1 index best best_number number file address
    local best_live best_live_number

    index=$(index_for "$name")
    best_number=-1
    best=
    best_live=
    best_live_number=-1
    for file in "${state_dir}"/t*.json; do
        [ -f "$file" ] || continue
        [ "$(jq -r '.name // empty' "$file")" = "$name" ] || continue
        address=$(basename "$file" .json)
        number=${address#t}
        case "$number" in
            '' | *[!0-9]*) number=0 ;;
        esac
        if [ "$(jq -r '.state' "$file")" = "live" ]; then
            if [ "$number" -gt "$best_live_number" ]; then
                best_live=$address
                best_live_number=$number
            fi
        elif [ "$number" -gt "$best_number" ]; then
            best=$address
            best_number=$number
        fi
    done

    if [ -n "$best_live" ]; then
        best=$best_live
    fi

    if [ -n "$best" ]; then
        printf '%s' "$best" >"$index"
    else
        rm -f "$index"
    fi
}

record_for() {
    local target=$1 file
    file=$(resolve_terminal "$target" 2>/dev/null) || return 1
    cat "$file"
}

case "$command_name" in
    server)
        printf '{}\n'
        ;;
    get)
        target=${1:-}
        if [ -n "${STUB_HC_GET_JSON:-}" ]; then
            printf '%s\n' "$STUB_HC_GET_JSON"
            exit 0
        fi
        record=$(record_for "$target") || {
            printf '{"error":{"kind":"not_found","message":"no terminal"}}\n' >&2
            exit 3
        }
        if [ -n "${STUB_HC_STATUS:-}" ]; then
            record=$(printf '%s' "$record" |
                jq --arg status "$STUB_HC_STATUS" '.status = $status')
        fi
        if [ -n "${STUB_HC_STATE_OVERRIDE:-}" ]; then
            record=$(printf '%s' "$record" |
                jq --arg state "$STUB_HC_STATE_OVERRIDE" '.state = $state')
        fi
        printf '%s\n' "$record"
        ;;
    ls)
        [ -z "${STUB_HC_LS_FAIL:-}" ] || exit 1
        include_finished=0
        for arg in "$@"; do
            [ "$arg" = "--all" ] && include_finished=1
        done
        output=$(jq -s --argjson all "$include_finished" '
            {terminals: map(select($all == 1 or .state == "live")), seq: 1}
        ' "${state_dir}"/t*.json 2>/dev/null || true)
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
        else
            printf '{"terminals":[],"seq":1}\n'
        fi
        ;;
    rm)
        target=${1:-}
        file=$(resolve_terminal "$target") || {
            printf '{"error":{"kind":"not_found"}}\n' >&2
            exit 3
        }
        state=$(jq -r '.state' "$file")
        [ "$state" = "finished" ] || {
            printf '{"error":{"kind":"live"}}\n' >&2
            exit 1
        }
        name=$(jq -r '.name // empty' "$file")
        address=$(jq -r '.address' "$file")
        rm -f "$file"
        [ -n "$name" ] && refresh_index "$name"
        printf '{"removed":"%s"}\n' "$address"
        ;;
    kill)
        target=${1:-}
        file=$(resolve_terminal "$target") || {
            printf '{"error":{"kind":"not_found"}}\n' >&2
            exit 3
        }
        jq '.state = "finished" | .exit_code = 1' "$file" >"${file}.new"
        mv "${file}.new" "$file"
        cat "$file"
        ;;
    label)
        target=${1:-}
        shift || true
        file=$(resolve_terminal "$target") || {
            printf '{"error":{"kind":"not_found"}}\n' >&2
            exit 3
        }
        [ -z "${STUB_HC_LABEL_FAIL:-}" ] || exit 1
        for pairs in "$@"; do
            key=${pairs%%=*}
            value=${pairs#*=}
            if [ "$key" = "$pairs" ] || [ -z "$value" ]; then
                jq --arg key "$key" 'del(.labels[$key])' "$file" >"${file}.new"
            else
                jq --arg key "$key" --arg value "$value" \
                    '.labels[$key] = $value' "$file" >"${file}.new"
            fi
            mv "${file}.new" "$file"
        done
        cat "$file"
        ;;
    run)
        name=
        cwd=
        labels='{}'
        argv=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --name)
                    name=$2
                    shift 2
                    ;;
                --cwd)
                    cwd=$2
                    shift 2
                    ;;
                --label)
                    pairs=$2
                    key=${pairs%%=*}
                    value=${pairs#*=}
                    if [ -z "${STUB_HC_STRIP_RUN_LABELS:-}" ]; then
                        labels=$(jq -c --arg key "$key" --arg value "$value" \
                            '. + {($key): $value}' <<<"$labels")
                    fi
                    shift 2
                    ;;
                --bg | --no-parent | --outlive-parent)
                    shift
                    ;;
                --parent | --timeout)
                    shift 2
                    ;;
                --)
                    shift
                    argv=("$@")
                    break
                    ;;
                *)
                    shift
                    ;;
            esac
        done

        [ -z "${STUB_HC_RUN_FAIL:-}" ] || {
            printf '{"error":{"kind":"spawn_failed"}}\n' >&2
            exit 1
        }

        index=$(index_for "$name")
        if [ -f "$index" ]; then
            address=$(cat "$index")
            if [ -f "${state_dir}/${address}.json" ] &&
                [ "$(jq -r '.state' "${state_dir}/${address}.json")" = "live" ]; then
                printf '{"error":{"kind":"name_taken"}}\n' >&2
                exit 1
            fi
        fi

        counter=$(cat "${state_dir}/.next" 2>/dev/null || printf '0')
        counter=$((counter + 1))
        printf '%s' "$counter" >"${state_dir}/.next"
        address="t${counter}"
        run_state="live"
        [ -z "${STUB_HC_RUN_FINISHED:-}" ] || run_state="finished"
        argv_json=$(printf '%s\n' "${argv[@]}" | jq -R . | jq -s .)

        jq -n \
            --arg address "$address" \
            --arg name "$name" \
            --arg cwd "$cwd" \
            --arg state "$run_state" \
            --argjson labels "$labels" \
            --argjson argv "$argv_json" \
            '{address: $address, name: $name, cwd: $cwd, state: $state,
              status: "idle", labels: $labels, argv: $argv}' \
            >"${state_dir}/${address}.json"
        printf '%s' "$address" >"$index"
        printf '{"address":"%s","name":"%s","state":"%s"}\n' \
            "$address" "$name" "$run_state"

        # Simulate the launched program so the codex/opencode stubs observe
        # resumes and new sessions.
        if [ "${#argv[@]}" -gt 0 ]; then
            "${argv[@]}" >/dev/null 2>&1 || true
        fi
        ;;
    attach)
        printf '{"attached":"%s"}\n' "${1:-}"
        ;;
    read)
        ;;
    wait)
        printf '{"ended":true,"reason":"status"}\n'
        ;;
    *)
        ;;
esac
STUB

cat >"${bin}/codex" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'codex %s\n' "$*" >>"${STUB_CODEX_LOG:?}"

command_name=${1:-}
case "$command_name" in
    exec)
        [ -z "${STUB_CODEX_BOOTSTRAP_FAIL:-}" ] || {
            printf 'bootstrap failed\n' >&2
            exit 1
        }
        if [ -n "${STUB_CODEX_BOOTSTRAP_NO_THREAD:-}" ]; then
            printf '{"type":"turn.completed","usage":{}}\n'
            exit 0
        fi
        thread=${STUB_CODEX_THREAD_ID:-}
        if [ -z "$thread" ]; then
            counter=$(cat "${STUB_CODEX_STATE:?}/counter" 2>/dev/null ||
                printf '0')
            counter=$((counter + 1))
            printf '%s' "$counter" >"${STUB_CODEX_STATE}/counter"
            thread=$(printf '00000000-0000-4000-8000-%012d' "$counter")
        fi
        printf '%s\n' "$thread" >>"${STUB_CODEX_STATE}/threads"
        printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
        [ -n "${STUB_CODEX_BOOTSTRAP_NO_COMPLETE:-}" ] ||
            printf '{"type":"turn.completed","usage":{}}\n'
        ;;
    resume)
        thread=${2:-}
        if [ -n "${STUB_CODEX_RESUME_FAIL:-}" ]; then
            exit 1
        fi
        if [ -n "${STUB_CODEX_RESUME_FAIL:-}" ] ||
            ! grep -Fxq "$thread" "${STUB_CODEX_STATE:?}/threads" 2>/dev/null; then
            printf 'Error: No saved session found with ID %s\n' "$thread" >&2
            exit 1
        fi
        printf 'Error: stdin is not a terminal\n' >&2
        ;;
    --version)
        printf 'codex-cli 0.167.0\n'
        ;;
    *)
        ;;
esac
STUB

cat >"${bin}/opencode" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'opencode %s\n' "$*" >>"${STUB_OPENCODE_LOG:?}"

command_name=${1:-}
case "$command_name" in
    session)
        subcommand=${2:-}
        case "$subcommand" in
            list)
                [ -z "${STUB_OPENCODE_LIST_FAIL:-}" ] || exit 1
                if [ -f "${STUB_OPENCODE_STATE:?}/sessions" ]; then
                    jq -R -s '
                        split("\n") | map(select(length > 0)) |
                        map({id: .})
                    ' <"${STUB_OPENCODE_STATE}/sessions"
                else
                    printf '[]\n'
                fi
                ;;
            delete)
                session=${3:-}
                if [ -f "${STUB_OPENCODE_STATE:?}/sessions" ]; then
                    grep -Fxv "$session" "${STUB_OPENCODE_STATE}/sessions" \
                        >"${STUB_OPENCODE_STATE}/sessions.new" || true
                    mv "${STUB_OPENCODE_STATE}/sessions.new" \
                        "${STUB_OPENCODE_STATE}/sessions"
                fi
                ;;
        esac
        ;;
    --standalone)
        session=
        while [ $# -gt 0 ]; do
            case "$1" in
                --session | -s)
                    session=$2
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        if [ -n "$session" ]; then
            printf '%s\n' "$session" >>"${STUB_OPENCODE_STATE:?}/sessions"
        fi
        ;;
    --version)
        printf 'opencode v2.2.6\n'
        ;;
    *)
        ;;
esac
STUB

chmod 0755 "${bin}/hc" "${bin}/codex" "${bin}/opencode"
mkdir -p "${tmp}/codex-state" "${tmp}/opencode-state"

export PATH="${bin}:${PATH}"
export STUB_HC_STATE="${state}"
export STUB_HC_LOG="${log}"
export STUB_CODEX_STATE="${tmp}/codex-state"
export STUB_CODEX_LOG="${codex_log}"
export STUB_OPENCODE_STATE="${tmp}/opencode-state"
export STUB_OPENCODE_LOG="${opencode_log}"
export AGENTS_TEAM_DIR="${repo_dir}/team"
export AGENTS_TEAM_WORKSPACE="${repo_dir}"
export AGENTS_TEAM_WORKSPACE_ID="/host/projects/team"
export AGENTS_TEAM_RUNTIME_DIR="${runtime}"

unset AGENTS_TEAM_PLANNER_MODEL || true
unset AGENTS_TEAM_IMPLEMENTER_MODEL || true

fail() {
    printf 'team test failed: %s\n' "$*" >&2
    if [ -s "$log" ]; then
        printf '%s\n' '--- hc log ---' >&2
        cat "$log" >&2
    fi
    if [ -s "$codex_log" ]; then
        printf '%s\n' '--- codex log ---' >&2
        cat "$codex_log" >&2
    fi
    if [ -s "$opencode_log" ]; then
        printf '%s\n' '--- opencode log ---' >&2
        cat "$opencode_log" >&2
    fi
    if [ -s "$team_log" ]; then
        printf '%s\n' '--- team log ---' >&2
        cat "$team_log" >&2
    fi
    exit 1
}

expect_log() {
    grep -Fq -- "$1" "$log" || fail "expected hc command containing: $1"
}

expect_no_log() {
    if grep -Fq -- "$1" "$log"; then
        fail "unexpected hc command containing: $1"
    fi
}

expect_codex_log() {
    grep -Fq -- "$1" "$codex_log" || fail "expected codex command containing: $1"
}

expect_no_codex_log() {
    if grep -Fq -- "$1" "$codex_log"; then
        fail "unexpected codex command containing: $1"
    fi
}

expect_no_codex_resume_prompt() {
    if grep '^codex resume ' "$codex_log" | grep -Fq -- "$1"; then
        fail "Codex resume replayed the bootstrap prompt: $1"
    fi
}

expect_opencode_log() {
    grep -Fq -- "$1" "$opencode_log" ||
        fail "expected opencode command containing: $1"
}

expect_no_opencode_log() {
    if grep -Fq -- "$1" "$opencode_log"; then
        fail "unexpected opencode command containing: $1"
    fi
}

run_team() {
    : >"$log"
    : >"$codex_log"
    : >"$opencode_log"
    "${repo_dir}/team/team.sh" "$@"
}

run_team_capture() {
    : >"$log"
    : >"$codex_log"
    : >"$opencode_log"
    "${repo_dir}/team/team.sh" "$@" 2>"$team_log"
}

expect_team_log() {
    grep -Fq -- "$1" "$team_log" || fail "expected team output containing: $1"
}

count_runs() {
    grep -c '^hc run ' "$log" || true
}

count_bootstraps() {
    grep -c '^codex exec ' "$codex_log" || true
}

count_codex_resumes() {
    grep -c '^codex resume ' "$codex_log" || true
}

record_for() {
    hc get "$1" --json
}

label_of() {
    record_for "$1" | jq -r --arg key "$2" '.labels[$key] // empty'
}

address_of() {
    record_for "$1" | jq -r '.address // empty'
}

finish_terminal() {
    local file
    file="${state}/$(address_of "$1").json"
    jq '.state = "finished"' "$file" >"${file}.new"
    mv "${file}.new" "$file"
    printf 'finished\n' >"$file.state"
}

add_terminal() {
    local name=$1 terminal_state=$2 labels=$3 address=$4
    jq -n \
        --arg address "$address" \
        --arg name "$name" \
        --arg state "$terminal_state" \
        --argjson labels "$labels" \
        '{address: $address, name: $name, cwd: "/workspace", state: $state,
          status: "idle", labels: $labels, argv: []}' \
        >"${state}/${address}.json"
}

make_terminal() {
    local name=$1 terminal_state=$2 labels=$3 address=$4 counter current
    add_terminal "$name" "$terminal_state" "$labels" "$address"
    printf '%s' "$address" >"${state}/.name-${name}"
    counter=${address#t}
    current=$(cat "${state}/.next" 2>/dev/null || printf '0')
    if [ "$counter" -gt "$current" ]; then
        printf '%s' "$counter" >"${state}/.next"
    fi
}

reset_state() {
    rm -f "${state}"/t*.json "${state}"/.name-* "${state}/.next" \
        "${state}"/*.state
    rm -f "${tmp}/codex-state/threads" "${tmp}/codex-state/counter" \
        "${tmp}/opencode-state/sessions"
    unset STUB_HC_GET_JSON STUB_HC_STATUS STUB_HC_RUN_FAIL \
        STUB_HC_RUN_FINISHED STUB_HC_STRIP_RUN_LABELS STUB_HC_LABEL_FAIL \
        STUB_HC_STATE_OVERRIDE STUB_HC_LS_FAIL \
        STUB_CODEX_BOOTSTRAP_FAIL STUB_CODEX_BOOTSTRAP_NO_THREAD \
        STUB_CODEX_BOOTSTRAP_NO_COMPLETE STUB_CODEX_RESUME_FAIL \
        STUB_CODEX_THREAD_ID \
        STUB_OPENCODE_LIST_FAIL AGENTS_TEAM_PLANNER_MODEL \
        AGENTS_TEAM_IMPLEMENTER_MODEL || true
}

# A first start creates one native conversation per role. Codex gets an exact
# ID from a neutral bootstrap and then opens the TUI on that same session.
run_team_capture

[ "$(count_runs)" -eq 2 ] ||
    fail "expected two role launches, got $(count_runs)"
expect_log "hc run --bg --name implementer"
expect_log "hc run --bg --name planner"
expect_log "OPENCODE_CONFIG="
expect_opencode_log "opencode --standalone --session ses_"
expect_codex_log "codex exec --json"
expect_codex_log "--sandbox read-only"
expect_codex_log "This is a session bootstrap."
expect_codex_log "developer_instructions="
expect_codex_log "codex resume "
expect_codex_log "-c developer_instructions="
expect_no_codex_resume_prompt "This is a session bootstrap. Reply with exactly READY. Do not inspect or modify any files, do not run tools, and do not start any work."
expect_codex_log "Approve this plan for implementation?"
expect_log "hc attach planner"
expect_no_log " -m "
expect_no_log "hc rm "

implementer_session=$(label_of implementer session)
planner_session=$(label_of planner session)
[ -n "$implementer_session" ] || fail "implementer session label is missing"
[ -n "$planner_session" ] || fail "planner session label is missing"
case "$implementer_session" in
    ses_*) ;;
    *) fail "implementer session label is not an OpenCode ID" ;;
esac
printf '%s' "$planner_session" |
    grep -Eq '^[0-9a-fA-F-]{36}$' ||
    fail "planner session label is not a Codex UUID"

[ "$(label_of implementer role)" = "implementer" ] ||
    fail "implementer role label is wrong"
[ "$(label_of planner role)" = "planner" ] ||
    fail "planner role label is wrong"
[ "$(label_of implementer workspace)" = "/host/projects/team" ] ||
    fail "implementer workspace label is wrong"
[ "$(label_of planner workspace)" = "/host/projects/team" ] ||
    fail "planner workspace label is wrong"
[ "$(label_of implementer task-state)" = "unknown" ] ||
    fail "new implementer task state must be unknown"
[ "$(label_of planner task-state)" = "unknown" ] ||
    fail "new planner task state must be unknown"
expect_team_log "implementer task state=unknown"
expect_team_log "planner task state=unknown"

jq -e --arg role "${repo_dir}/team/implementer.md" \
    '.instructions == [$role] and (.model == null)' \
    "${runtime}/opencode.json" >/dev/null ||
    fail "implementer config does not load the role file or unexpectedly sets a model"
expect_codex_log "Runtime recovery state: task-state=unknown"
[ "$(count_codex_resumes)" -eq 1 ] ||
    fail "a new Codex session should open exactly one TUI resume"

# The role files define the lightweight protocol and the recovery safeguards.
planner_role="${repo_dir}/team/planner.md"
implementer_role="${repo_dir}/team/implementer.md"

for field in objective context scope constraints acceptance validation; do
    grep -Fqi "${field}:" "$planner_role" ||
        fail "planner delegation protocol is missing: ${field}"
done
grep -Fqi "expected report:" "$planner_role" ||
    fail "planner delegation protocol is missing: expected report"
grep -Fqi "omit fields that do not apply" "$planner_role" ||
    fail "planner protocol does not allow omitting irrelevant fields"
grep -Fqi "correcting a prior task" "$planner_role" ||
    fail "planner protocol lacks correction guidance"
grep -Fqi "task-state=in_progress" "$planner_role" ||
    fail "planner protocol lacks task-state marking"
grep -Fqi "Do not delegate a task if either" "$planner_role" ||
    fail "planner protocol lacks label-failure guard"
grep -Fqi "never replay the previous task prompt" "$planner_role" ||
    fail "planner protocol lacks replay protection"
grep -Fqi "explicit confirmation" "$planner_role" ||
    fail "planner protocol lacks confirmation guidance"
grep -Fqi "prior findings" "$implementer_role" ||
    fail "implementer protocol does not direct use of prior findings"
grep -Fqi "only the code relevant" "$implementer_role" ||
    fail "implementer protocol does not limit inspection"
grep -Fqi "missing or ambiguous" "$implementer_role" ||
    fail "implementer protocol lacks ambiguity guidance"
grep -Fqi "unresolved issues:" "$implementer_role" ||
    fail "implementer protocol lacks unresolved-issues reporting"
grep -Fqi "validation evidence:" "$implementer_role" ||
    fail "implementer protocol lacks validation-evidence reporting"
grep -Fqi "do not replay" "$implementer_role" ||
    fail "implementer protocol lacks replay protection"

# Live roles are reused without launching or removing anything, and the status
# summary precedes the attach.
run_team_capture
[ "$(count_runs)" -eq 0 ] || fail "live roles were launched again"
expect_no_log "hc rm "
expect_log "hc attach planner"
expect_team_log "agents-team: implementer: state=live status=idle"
expect_team_log "agents-team: planner: state=live status=idle"
awk '
    /agents-team: implementer: state=/ && !implementer { implementer = NR }
    /agents-team: planner: state=/ && !planner { planner = NR }
    /agents-team: attaching to planner/ && !attach { attach = NR }
    END {
        exit !(attach && implementer && planner &&
               implementer < attach && planner < attach)
    }
' "$team_log" ||
    fail "status summary was not printed before attaching"

implementer_address=$(address_of implementer)
planner_address=$(address_of planner)
[ "$(label_of implementer session)" = "$implementer_session" ] ||
    fail "live reuse changed the implementer session"
[ "$(label_of planner session)" = "$planner_session" ] ||
    fail "live reuse changed the planner session"

# A busy live role is still reused, not restarted.
export STUB_HC_STATUS=working
run_team
[ "$(count_runs)" -eq 0 ] || fail "busy live roles were launched again"
unset STUB_HC_STATUS || true

# A live terminal is reused only when its role and workspace labels match the
# current invocation. A different workspace is rejected without attaching,
# removing, or killing the existing terminal.
hc label planner workspace=/host/projects/other >/dev/null
if run_team_capture; then
    fail "a live terminal from another workspace was reused"
fi
expect_team_log "refusing to attach"
expect_no_log "hc attach"
expect_no_log "hc rm "
expect_no_log "hc kill "
[ "$(label_of planner workspace)" = "/host/projects/other" ] ||
    fail "the rejected live planner was modified"
[ "$(record_for planner | jq -r '.state')" = "live" ] ||
    fail "the rejected live planner was not left running"
hc label planner workspace=/host/projects/team >/dev/null

# Missing labels on a live terminal are also rejected without touching it.
hc label implementer role= workspace= >/dev/null
if run_team_capture; then
    fail "an unlabeled live terminal was reused"
fi
expect_team_log "refusing to attach"
expect_no_log "hc attach"
expect_no_log "hc rm "
expect_no_log "hc kill "
[ "$(record_for implementer | jq -r '.state')" = "live" ] ||
    fail "the unlabeled live implementer was not left running"
hc label implementer role=implementer workspace=/host/projects/team >/dev/null

# Malformed live JSON without labels is rejected in the same way.
export STUB_HC_GET_JSON='{"state":"live","unexpected":"field"}'
if run_team_capture; then
    fail "a live terminal without usable labels was reused"
fi
unset STUB_HC_GET_JSON || true
expect_team_log "refusing to attach"
expect_no_log "hc attach"
expect_no_log "hc rm "
expect_no_log "hc kill "

# Unknown state is reused only when role/workspace labels validate.
export STUB_HC_STATE_OVERRIDE=unknown
run_team_capture
unset STUB_HC_STATE_OVERRIDE || true
expect_log "hc attach planner"
expect_no_log "hc rm "
expect_team_log "reusing implementer terminal with unknown state"

# Malformed unknown state without labels is fail-closed, like the live branch.
export STUB_HC_GET_JSON='{"status":"idle"}'
if run_team_capture; then
    fail "an unknown-state terminal without usable labels was reused"
fi
expect_team_log "could not be validated"
expect_no_log "hc attach"
expect_no_log "hc rm "
expect_no_log "hc kill "
unset STUB_HC_GET_JSON || true

export STUB_HC_GET_JSON='not-json'
if run_team_capture; then
    fail "an unreadable terminal was reused"
fi
expect_team_log "could not be validated"
expect_no_log "hc attach"
expect_no_log "hc rm "
expect_no_log "hc kill "
unset STUB_HC_GET_JSON || true

# A finished implementer resumes the same native session; the old record is
# removed only after the new terminal carries the confirmed association.
finish_terminal implementer
old_implementer_address=$implementer_address
run_team_capture
[ "$(count_runs)" -eq 1 ] || fail "finished implementer was not restarted alone"
expect_log "hc run --bg --name implementer"
expect_no_log "hc run --bg --name planner"
expect_no_log "hc rm $old_implementer_address"
expect_opencode_log "opencode --standalone --session $implementer_session"
[ -f "${state}/${old_implementer_address}.json" ] ||
    fail "resumed implementer record was removed without load evidence"
expect_team_log "keeping previous implementer terminal ${old_implementer_address}"
[ "$(address_of implementer)" != "$old_implementer_address" ] ||
    fail "finished implementer was not replaced"
[ "$(label_of implementer session)" = "$implementer_session" ] ||
    fail "implementer resume changed the session ID"
[ "$(label_of implementer task-state)" = "unknown" ] ||
    fail "implementer task state was not preserved"
[ "$(count_runs)" -eq 1 ] || fail "unexpected extra launches"

# A finished planner resumes the exact Codex session without a new bootstrap.
finish_terminal planner
old_planner_address=$planner_address
run_team_capture
[ "$(count_runs)" -eq 1 ] || fail "finished planner was not restarted alone"
expect_log "hc run --bg --name planner"
expect_no_log "hc run --bg --name implementer"
expect_codex_log "codex resume $planner_session --no-daemon"
expect_no_codex_log "codex exec"
expect_no_log "hc rm $old_planner_address"
[ -f "${state}/${old_planner_address}.json" ] ||
    fail "resumed planner record was removed without load evidence"
expect_team_log "keeping previous planner terminal ${old_planner_address}"
[ "$(address_of planner)" != "$old_planner_address" ] ||
    fail "finished planner was not replaced"
[ "$(label_of planner session)" = "$planner_session" ] ||
    fail "planner resume changed the session ID"
[ "$(count_codex_resumes)" -eq 1 ] ||
    fail "planner resume should use one explicit TUI resume"

# An in-progress task keeps its state and produces a recovery warning.
hc label planner task-state=in_progress >/dev/null
finish_terminal planner
run_team_capture
[ "$(label_of planner task-state)" = "in_progress" ] ||
    fail "planner task state was not preserved on resume"
expect_team_log "task state=in_progress"
expect_team_log "explicit confirmation"
expect_codex_log "Runtime recovery state: task-state=in_progress"
expect_no_codex_log "This is a session bootstrap."

# Fresh mode creates new native conversations, keeps the old histories, and
# does not delete or replace live terminals.
implementer_before=$(label_of implementer session)
planner_before=$(label_of planner session)
finish_terminal implementer
finish_terminal planner
run_team_capture --fresh
[ "$(count_runs)" -eq 2 ] || fail "fresh mode did not start both roles"
[ "$(count_bootstraps)" -eq 1 ] || fail "fresh mode did not bootstrap Codex"
implementer_fresh=$(label_of implementer session)
planner_fresh=$(label_of planner session)
[ "$implementer_fresh" != "$implementer_before" ] ||
    fail "fresh mode reused the implementer session"
[ "$planner_fresh" != "$planner_before" ] ||
    fail "fresh mode reused the planner session"
grep -Fxq "$implementer_before" "${tmp}/opencode-state/sessions" ||
    fail "fresh mode deleted the previous OpenCode session"
grep -Fxq "$planner_before" "${tmp}/codex-state/threads" ||
    fail "fresh mode deleted the previous Codex session"
expect_no_codex_log "codex delete"
expect_no_opencode_log "session delete"
expect_log "hc rm "
[ "$(label_of implementer workspace)" = "/host/projects/team" ] ||
    fail "fresh implementer lost the workspace label"

# Fresh mode leaves live terminals untouched.
run_team_capture --fresh
[ "$(count_runs)" -eq 0 ] || fail "fresh mode restarted live roles"
expect_no_log "hc rm "
expect_team_log "fresh mode: keeping live implementer terminal"
expect_team_log "fresh mode: keeping live planner terminal"

# A finished record from another workspace is never adopted and is retained.
finish_terminal implementer
old_wrong_address=$(address_of implementer)
old_wrong_session=$implementer_fresh
hc label implementer workspace=/host/projects/other >/dev/null
run_team_capture
new_wrong_session=$(label_of implementer session)
[ "$new_wrong_session" != "$old_wrong_session" ] ||
    fail "a session from another workspace was adopted"
expect_team_log "another workspace"
[ -f "${state}/${old_wrong_address}.json" ] ||
    fail "the record from another workspace was removed"

# A saved Codex ID that cannot be resumed fails clearly. The launcher must not
# retry with --last, replay a task, or start an ambiguous fallback.
finish_terminal planner
old_missing_address=$(address_of planner)
old_missing_session=$(label_of planner session)
export STUB_CODEX_RESUME_FAIL=1
export STUB_HC_RUN_FINISHED=1
if run_team_capture; then
    fail "a broken saved Codex session was reported as success"
fi
unset STUB_CODEX_RESUME_FAIL STUB_HC_RUN_FINISHED || true
expect_team_log "could not be resumed"
expect_no_codex_log "codex exec"
expect_no_codex_resume_prompt "This is a session bootstrap."
[ -f "${state}/${old_missing_address}.json" ] ||
    fail "a failed Codex resume removed the previous record"
[ "$(label_of planner session)" = "$old_missing_session" ] ||
    fail "a failed Codex resume changed the saved association"
run_team_capture
[ "$(label_of planner session)" = "$old_missing_session" ] ||
    fail "planner resume did not recover after the simulated failure"

finish_terminal implementer
old_missing_opencode_address=$(address_of implementer)
old_missing_opencode=$new_wrong_session
grep -Fxv "$old_missing_opencode" "${tmp}/opencode-state/sessions" \
    >"${tmp}/opencode-state/sessions.new" || true
mv "${tmp}/opencode-state/sessions.new" "${tmp}/opencode-state/sessions"
run_team_capture
[ "$(label_of implementer session)" != "$old_missing_opencode" ] ||
    fail "a missing OpenCode session ID was reused"
expect_team_log "is not available"
[ ! -f "${state}/${old_missing_opencode_address}.json" ] ||
    fail "the stale implementer record was not removed after transfer"

# Multiple saved records for one role with different IDs are ambiguous; the
# launcher must not choose one arbitrarily.
finish_terminal implementer
ambiguous_original=$(label_of implementer session)
add_terminal implementer finished \
    '{"team":"agents","role":"implementer","workspace":"/host/projects/team","session":"ses_duplicate0000000000000000","task-state":"completed"}' \
    t900
run_team_capture
ambiguous_new=$(label_of implementer session)
[ "$ambiguous_new" != "$ambiguous_original" ] ||
    fail "an ambiguous record was adopted as-is"
[ "$ambiguous_new" != "ses_duplicate0000000000000000" ] ||
    fail "an arbitrary ambiguous record was adopted"
expect_team_log "ambiguous session association for implementer"
rm -f "${state}/t900.json"

# A failure between launch and label transfer keeps the old completed record.
finish_terminal implementer
old_failure_address=$(address_of implementer)
old_failure_session=$(label_of implementer session)
export STUB_HC_RUN_FAIL=1
if run_team_capture; then
    fail "a failed launch was reported as success"
fi
unset STUB_HC_RUN_FAIL || true
[ -f "${state}/${old_failure_address}.json" ] ||
    fail "a failed launch removed the previous record"
[ "$(label_of implementer session)" = "$old_failure_session" ] ||
    fail "a failed launch changed the previous association"

# Missing labels on a new terminal are repaired before the old record is
# removed.
export STUB_HC_STRIP_RUN_LABELS=1
run_team_capture
unset STUB_HC_STRIP_RUN_LABELS || true
[ "$(address_of implementer)" != "$old_failure_address" ] ||
    fail "label repair did not start a new implementer"
[ "$(label_of implementer session)" = "$old_failure_session" ] ||
    fail "label repair lost the session association"
[ "$(label_of implementer workspace)" = "/host/projects/team" ] ||
    fail "label repair lost the workspace association"
[ -f "${state}/${old_failure_address}.json" ] ||
    fail "label repair removed the old resumed record without load evidence"
expect_team_log "keeping previous implementer terminal ${old_failure_address}"
expect_log "hc label "

# If association labels cannot be confirmed, the new terminal is cleaned up and
# the old record remains.
finish_terminal implementer
old_unconfirmed_address=$(address_of implementer)
export STUB_HC_STRIP_RUN_LABELS=1
export STUB_HC_LABEL_FAIL=1
if run_team_capture; then
    fail "unconfirmed association was reported as success"
fi
unset STUB_HC_STRIP_RUN_LABELS STUB_HC_LABEL_FAIL || true
[ -f "${state}/${old_unconfirmed_address}.json" ] ||
    fail "unconfirmed association removed the previous record"

# Bootstrap failures do not create a planner terminal or a TUI session.
reset_state
export STUB_CODEX_BOOTSTRAP_FAIL=1
if run_team_capture; then
    fail "bootstrap failure was reported as success"
fi
unset STUB_CODEX_BOOTSTRAP_FAIL || true
if record_for planner >/dev/null 2>&1; then
    fail "bootstrap failure created a planner terminal"
fi
expect_no_codex_log "codex resume"

reset_state
export STUB_CODEX_BOOTSTRAP_NO_THREAD=1
if run_team_capture; then
    fail "bootstrap without a thread ID was reported as success"
fi
unset STUB_CODEX_BOOTSTRAP_NO_THREAD || true

reset_state
export STUB_CODEX_BOOTSTRAP_NO_COMPLETE=1
if run_team_capture; then
    fail "incomplete bootstrap was reported as success"
fi
unset STUB_CODEX_BOOTSTRAP_NO_COMPLETE || true

# If the previous records cannot be listed, cleanup is skipped and even a
# record from another workspace is preserved.
reset_state
make_terminal planner live \
    '{"team":"agents","role":"planner","workspace":"/host/projects/team","session":"00000000-0000-4000-8000-000000000001","task-state":"completed"}' \
    t1
make_terminal implementer finished \
    '{"team":"agents","role":"implementer","workspace":"/host/projects/other","session":"ses_other00000000000000000","task-state":"completed"}' \
    t2
export STUB_HC_LS_FAIL=1
run_team_capture
unset STUB_HC_LS_FAIL || true
expect_team_log "skipping cleanup"
expect_no_log "hc rm "
expect_log "hc attach planner"
[ -f "${state}/t2.json" ] ||
    fail "cleanup removed a different-workspace record when hc ls failed"
[ "$(record_for implementer | jq -r '.state')" = "live" ] ||
    fail "the implementer was not started when hc ls failed"

# Model values are provider-neutral inputs, preserved by bootstrap and resume.
reset_state
run_team_with_models() {
    AGENTS_TEAM_PLANNER_MODEL="planner-test-model" \
        AGENTS_TEAM_IMPLEMENTER_MODEL="implementer-test-model" \
        "${repo_dir}/team/team.sh" "$@"
}

: >"$log"
: >"$codex_log"
: >"$opencode_log"
run_team_with_models
expect_codex_log "codex exec --json"
expect_codex_log "-m planner-test-model"
expect_codex_log "codex resume "
expect_opencode_log "opencode --standalone --session ses_"
jq -e '.model == "implementer-test-model"' "${runtime}/opencode.json" >/dev/null ||
    fail "implementer model was not written to the OpenCode config"

# Fresh mode leaves live sessions untouched even when their labels conflict
# with the saved association.
planner_conflict_address=$(address_of planner)
hc label planner session=00000000-0000-4000-8000-999999999999 >/dev/null
run_team_capture --fresh
[ "$(count_runs)" -eq 0 ] || fail "fresh mode restarted a conflicting live role"
expect_no_log "hc rm "
[ "$(address_of planner)" = "$planner_conflict_address" ] ||
    fail "fresh mode replaced a conflicting live planner"
expect_team_log "fresh mode: keeping live planner terminal"

printf 'team tests passed\n'
