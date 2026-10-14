#!/usr/bin/env bash
set -euo pipefail

sample_interval=${1:-30}
sample_count=${2:-960}
if ! [[ "$sample_interval" =~ ^[1-9][0-9]*$ && "$sample_count" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Usage: bash scripts/sample-memory.sh [interval-seconds] [sample-count]\n' >&2
    exit 2
fi

printf '# macOS %s, build %s\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
printf 'utc,pid,ppid,rss_kib,role\n'
trap 'exit 0' INT TERM

for ((sample_index = 0; sample_index < sample_count; sample_index++)); do
    sample_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    ps -axo pid=,ppid=,rss=,comm= | awk -v timestamp="$sample_timestamp" '
        {
            pid[NR] = $1
            parent[$1] = $2
            rss[$1] = $3
            name[$1] = $NF
        }
        END {
            for (i = 1; i <= NR; i++) {
                if (name[pid[i]] ~ /(^|\/)AgentBar$/) {
                    tracked[pid[i]] = 1
                    role[pid[i]] = "AgentBar"
                }
            }
            for (pass = 0; pass < NR; pass++) {
                added = 0
                for (i = 1; i <= NR; i++) {
                    if (!tracked[pid[i]] && tracked[parent[pid[i]]]) {
                        tracked[pid[i]] = 1
                        role[pid[i]] = "child"
                        added = 1
                    }
                }
                if (!added) break
            }
            for (i = 1; i <= NR; i++) {
                if (tracked[pid[i]]) {
                    printf "%s,%d,%d,%d,%s\n", timestamp, pid[i], parent[pid[i]], rss[pid[i]], role[pid[i]]
                }
            }
        }
    '
    if ((sample_index + 1 < sample_count)); then
        sleep "$sample_interval"
    fi
done
