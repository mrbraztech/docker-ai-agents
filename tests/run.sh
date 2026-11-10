#!/usr/bin/env bash
#
# Run the team and launcher checks. No Docker daemon is required.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

sh -n "${repo_dir}/agents.sh"
bash -n "${repo_dir}/team/team.sh"
bash -n "${repo_dir}/team/tui.sh"
bash -n "${repo_dir}/team/teamctl"
bash -n "${repo_dir}/tests/launcher-test.sh"
bash -n "${repo_dir}/tests/team-test.sh"
bash -n "${repo_dir}/tests/tui-test.sh"

for role in planner implementer; do
    file="${repo_dir}/team/${role}.md"
    [ -s "$file" ] || {
        printf 'missing role instructions: %s\n' "$file" >&2
        exit 1
    }
done

grep -Fq "Approve this plan for implementation?" \
    "${repo_dir}/team/planner.md"
grep -Fq "teamctl send planner" "${repo_dir}/team/implementer.md"

planner="${repo_dir}/team/planner.md"
for rolectl_command in send wait read; do
    grep -Fq "/opt/agents-team/teamctl ${rolectl_command} implementer" "$planner" || {
        printf 'planner instructions must use the absolute teamctl path for %s: %s\n' \
            "$rolectl_command" "$planner" >&2
        exit 1
    }
done
grep -Fq "/opt/agents-team/teamctl send planner" "$planner" || {
    printf 'planner instructions must use the absolute teamctl path for implementer reports: %s\n' \
        "$planner" >&2
    exit 1
}
if grep -Eq '(^|[^[:alnum:]_./-])hc (send|wait|read)' "$planner"; then
    printf 'planner instructions contain a bare hc command; use /opt/agents-team/teamctl: %s\n' \
        "$planner" >&2
    exit 1
fi

"${repo_dir}/tests/launcher-test.sh"
"${repo_dir}/tests/team-test.sh"
"${repo_dir}/tests/tui-test.sh"

printf 'all checks passed\n'
