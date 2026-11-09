#!/usr/bin/env bash
#
# Team launcher tests with a stub hc. They exercise live-session reuse, the
# finished-session lifecycle, role instruction loading, and model selection
# without starting a real container or Herdr Core.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin="${tmp}/bin"
state="${tmp}/state"
runtime="${tmp}/runtime"
log="${tmp}/hc.log"
team_log="${tmp}/team.log"

mkdir -p "$bin" "$state" "$runtime"

cat >"${bin}/hc" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

printf 'hc %s\n' "$*" >>"${STUB_HC_LOG:?}"

command_name=${1:-}
shift || true

case "$command_name" in
    server)
        printf '{}\n'
        ;;
    get)
        name=${1:-}
        if [ -f "${STUB_HC_STATE:?}/${name}" ]; then
            if [ -n "${STUB_HC_GET_JSON:-}" ]; then
                printf '%s\n' "$STUB_HC_GET_JSON"
                exit 0
            fi
            state=$(cat "${STUB_HC_STATE}/${name}")
            printf '{"name":"%s","state":"%s","status":"%s"}\n' \
                "$name" "$state" "${STUB_HC_STATUS:-idle}"
            exit 0
        fi
        printf '{"error":{"kind":"not_found","message":"no terminal"}}\n' >&2
        exit 3
        ;;
    rm)
        name=${1:-}
        rm -f "${STUB_HC_STATE:?}/${name}"
        printf '{"removed":"%s"}\n' "$name"
        ;;
    run)
        name=
        while [ $# -gt 0 ]; do
            case "$1" in
                --name)
                    name=$2
                    shift 2
                    ;;
                --bg | --no-parent | --outlive-parent)
                    shift
                    ;;
                --cwd | --label | --parent | --timeout)
                    shift 2
                    ;;
                --)
                    shift
                    break
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        if [ -f "${STUB_HC_STATE:?}/${name}" ]; then
            printf '{"error":{"kind":"name_taken"}}\n' >&2
            exit 1
        fi
        printf 'live\n' >"${STUB_HC_STATE}/${name}"
        printf '{"address":"t1","name":"%s","state":"live"}\n' "$name"
        ;;
    attach)
        printf '{"attached":"%s"}\n' "${1:-}"
        ;;
    read)
        ;;
    *)
        ;;
esac
STUB

for command in codex opencode; do
    cat >"${bin}/${command}" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
done

chmod 0755 "${bin}/hc" "${bin}/codex" "${bin}/opencode"

export PATH="${bin}:${PATH}"
export STUB_HC_STATE="${state}"
export STUB_HC_LOG="${log}"
export AGENTS_TEAM_DIR="${repo_dir}/team"
export AGENTS_TEAM_WORKSPACE="${repo_dir}"
export AGENTS_TEAM_RUNTIME_DIR="${runtime}"

unset AGENTS_TEAM_PLANNER_MODEL || true
unset AGENTS_TEAM_IMPLEMENTER_MODEL || true

fail() {
    printf 'team test failed: %s\n' "$*" >&2
    if [ -s "$log" ]; then
        printf '%s\n' '--- hc log ---' >&2
        cat "$log" >&2
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

run_team() {
    : >"$log"
    "${repo_dir}/team/team.sh"
}

run_team_capture() {
    : >"$log"
    "${repo_dir}/team/team.sh" 2>"$team_log"
}

expect_team_log() {
    grep -Fq -- "$1" "$team_log" || fail "expected team output containing: $1"
}

count_runs() {
    grep -c '^hc run ' "$log" || true
}

run_team

[ "$(count_runs)" -eq 2 ] || fail "expected two role launches, got $(count_runs)"
expect_log "hc run --bg --name implementer"
expect_log "hc run --bg --name planner"
expect_log "OPENCODE_CONFIG="
expect_log "opencode --standalone"
expect_log "codex --no-daemon"
expect_log "developer_instructions="
expect_log "Approve this plan for implementation?"
expect_log "hc attach planner"
expect_no_log " -m "

jq -e --arg role "${repo_dir}/team/implementer.md" \
    '.instructions == [$role] and (.model == null)' \
    "${runtime}/opencode.json" >/dev/null ||
    fail "implementer config does not load the role file or unexpectedly sets a model"

# The role files define the lightweight protocol, and the launcher loads it
# without adding infrastructure.
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
grep -Fq -- "expected report:" "$log" ||
    fail "planner protocol text was not loaded into the Codex instructions"

# Both live roles must be reused, and the status summary must report both
# roles before attaching without changing their state.
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
[ "$(cat "${state}/implementer")" = "live" ] ||
    fail "status reporting changed the implementer state"
[ "$(cat "${state}/planner")" = "live" ] ||
    fail "status reporting changed the planner state"

# A busy live role is still reused, not restarted.
export STUB_HC_STATUS=working
run_team
[ "$(count_runs)" -eq 0 ] || fail "busy live roles were launched again"
expect_no_log "hc rm "

# Missing or unexpected JSON fields must not prevent the planner attach. The
# roles are already live, so an unusable state must be reused, not removed.
unset STUB_HC_STATUS || true

export STUB_HC_GET_JSON='{"state":"live","unexpected":"field"}'
run_team_capture
expect_log "hc attach planner"
expect_no_log "hc rm "
expect_team_log "agents-team: implementer: state=live status=unknown"
expect_team_log "agents-team: planner: state=live status=unknown"

export STUB_HC_GET_JSON='{"status":"idle"}'
run_team_capture
expect_log "hc attach planner"
expect_no_log "hc rm "
expect_team_log "agents-team: implementer: state=unknown status=idle"
expect_team_log "agents-team: planner: state=unknown status=idle"

export STUB_HC_GET_JSON='{"state":{"unexpected":true},"status":["working"]}'
run_team_capture
expect_log "hc attach planner"
expect_no_log "hc rm "
expect_team_log "agents-team: implementer: state=unknown status=unknown"

export STUB_HC_GET_JSON='not-json'
run_team_capture
expect_log "hc attach planner"
expect_no_log "hc rm "
expect_team_log "agents-team: planner: state=unknown status=unknown"
unset STUB_HC_GET_JSON || true

# A finished implementer is removed and started again; the live planner is not
# restarted.
unset STUB_HC_STATUS || true
printf 'finished\n' >"${state}/implementer"
run_team
expect_log "hc rm implementer"
expect_log "hc run --bg --name implementer"
expect_no_log "hc run --bg --name planner"

# A finished planner follows the same supported lifecycle.
printf 'finished\n' >"${state}/planner"
run_team
expect_log "hc rm planner"
expect_log "hc run --bg --name planner"

# Model values are provider-neutral inputs, not hardcoded names.
rm -f "${state}/planner" "${state}/implementer"
run_team_with_models() {
    AGENTS_TEAM_PLANNER_MODEL="planner-test-model" \
        AGENTS_TEAM_IMPLEMENTER_MODEL="implementer-test-model" \
        "${repo_dir}/team/team.sh"
}

: >"$log"
run_team_with_models
expect_log "-m planner-test-model"
jq -e '.model == "implementer-test-model"' "${runtime}/opencode.json" >/dev/null ||
    fail "implementer model was not written to the OpenCode config"

printf 'team tests passed\n'
