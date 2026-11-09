#!/bin/bash
# Push a minimal heartbeat so the dashboard can tell if watcher itself is alive
set -euo pipefail

TOKEN=$(<"$HOME/.github_token")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BODY="{\"host\":\"watcher\",\"timestamp\":\"$TS\",\"uptime_s\":$(cut -d. -f1 /proc/uptime)}"

CONTENT=$(echo "$BODY" | base64 -w0)
SHA=$(curl -sf -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/mrtoadie/mrtoadie.github.io/contents/data/watcher.json" \
    | jq -r '.sha // empty' || true)

jq -n --arg m "watcher heartbeat: $TS" --arg c "$CONTENT" --arg b "main" \
    $( [ -n "$SHA" ] && printf -- '--arg s %s {message:$m,content:$c,sha:$s,branch:$b}' \
                          || printf '{message:$m,content:$c,branch:$b}' ) \
| curl -sf -X PUT -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/mrtoadie/mrtoadie.github.io/contents/data/watcher.json" \
    -d @- > /dev/null
