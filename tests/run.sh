#!/usr/bin/env bash
#
# Run the team and launcher checks. No Docker daemon is required.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

sh -n "${repo_dir}/agents.sh"
bash -n "${repo_dir}/team/team.sh"
bash -n "${repo_dir}/tests/launcher-test.sh"
bash -n "${repo_dir}/tests/team-test.sh"

for role in planner implementer; do
    file="${repo_dir}/team/${role}.md"
    [ -s "$file" ] || {
        printf 'missing role instructions: %s\n' "$file" >&2
        exit 1
    }
done

grep -Fq "Approve this plan for implementation?" \
    "${repo_dir}/team/planner.md"
grep -Fq "hc send planner" "${repo_dir}/team/implementer.md"

planner="${repo_dir}/team/planner.md"
for hc_command in send wait read; do
    grep -Fq "/home/agent/.local/bin/hc ${hc_command} implementer" "$planner" || {
        printf 'planner instructions must use the absolute hc path for %s: %s\n' \
            "$hc_command" "$planner" >&2
        exit 1
    }
done
grep -Fq "/home/agent/.local/bin/hc send planner" "$planner" || {
    printf 'planner instructions must use the absolute hc path for implementer reports: %s\n' \
        "$planner" >&2
    exit 1
}
if grep -Eq '(^|[^[:alnum:]_./-])hc (send|wait|read)' "$planner"; then
    printf 'planner instructions contain a bare hc command; use /home/agent/.local/bin/hc: %s\n' \
        "$planner" >&2
    exit 1
fi

"${repo_dir}/tests/launcher-test.sh"
"${repo_dir}/tests/team-test.sh"

printf 'all checks passed\n'
