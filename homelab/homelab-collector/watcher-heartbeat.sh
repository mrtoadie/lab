#!/bin/bash
# watcher-heartbeat.sh — push a minimal heartbeat so the dashboard can tell
# if watcher itself is alive.
#
# Same push pattern as collect.sh: fetch the current sha, PUT with sha when
# the file exists, without sha when creating it. Unlike the old version,
# every failure is logged — no silent death.
#
# Requirements: curl, jq, base64, bash >= 4
set -euo pipefail

GITHUB_USER="mrtoadie"
REPO="mrtoadie.github.io"
BRANCH="main"
REMOTE_PATH="data/watcher.json"
API="https://api.github.com/repos/$GITHUB_USER/$REPO/contents/$REMOTE_PATH"

TOKEN_FILE="$HOME/.github_token"
DATA_FILE="/tmp/watcher.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# ------------------------------ build payload ------------------------------

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
UPTIME=$(cut -d. -f1 /proc/uptime)

cat > "$DATA_FILE" <<EOF
{"host":"watcher","timestamp":"$TS","uptime_s":$UPTIME}
EOF

if ! jq -e . "$DATA_FILE" >/dev/null 2>&1; then
    log "✗ $DATA_FILE is not valid JSON — build failed"
    exit 1
fi

CONTENT=$(base64 -w0 "$DATA_FILE")

# ------------------------------- main logic -------------------------------

main() {
    if [ ! -r "$TOKEN_FILE" ]; then
        log "✗ token file not readable: $TOKEN_FILE"
        log "  hint: when run from cron/systemd, \$HOME may be empty —"
        log "        hardcode the path or set Environment=HOME=/home/toadie"
        exit 1
    fi
    TOKEN=$(<"$TOKEN_FILE")

    log "collecting heartbeat…"
    log "  timestamp: $TS"
    log "  uptime:    ${UPTIME}s"

    log "publishing to GitHub…"

    # Fetch the current sha. Empty output means "file does not exist yet".
    # Deliberately NOT using curl -f here: a 404 would kill the pipeline
    # before jq could run, and we want to distinguish 404 from other errors.
    SHA=$(curl -s --max-time 10 \
              -H "Authorization: Bearer $TOKEN" \
              -H "Accept: application/vnd.github+json" \
              "$API" \
           | jq -r '.sha // empty' 2>/dev/null || true)

    if [ -n "$SHA" ]; then
        log "  updating existing file (sha ${SHA:0:8})"
        PAYLOAD=$(jq -n --arg m "watcher heartbeat: $TS" --arg c "$CONTENT" \
                      --arg s "$SHA" --arg b "$BRANCH" \
                      '{message:$m, content:$c, sha:$s, branch:$b}')
    else
        log "  file does not exist yet — creating"
        PAYLOAD=$(jq -n --arg m "watcher heartbeat: $TS" --arg c "$CONTENT" \
                      --arg b "$BRANCH" \
                      '{message:$m, content:$c, branch:$b}')
    fi

    # Push and CAPTURE the response — the old version threw it away.
    HTTP_CODE=$(curl -s --max-time 15 -o /tmp/gh-response.json \
                    -w "%{http_code}" -X PUT \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Accept: application/vnd.github+json" \
                    "$API" -d "$PAYLOAD" || echo "000")

    case "$HTTP_CODE" in
        200)
            COMMIT=$(jq -r '.commit.sha[0:8] // "?"' /tmp/gh-response.json 2>/dev/null)
            log "✓ heartbeat pushed (commit ${COMMIT})"
            ;;
        422)
            log "✗ HTTP 422 — sha missing or stale:"
            jq -r '.message, (.errors[]?.message // empty)' /tmp/gh-response.json 2>/dev/null
            log "  likely the sha lookup above failed while the file exists"
            exit 1
            ;;
        409)
            log "✗ HTTP 409 — sha does not match the current file state:"
            jq -r '.message' /tmp/gh-response.json 2>/dev/null
            exit 1
            ;;
        401)
            log "✗ HTTP 401 — token invalid or expired"
            exit 1
            ;;
        *)
            log "✗ unexpected HTTP $HTTP_CODE:"
            head -c 400 /tmp/gh-response.json 2>/dev/null; echo
            exit 1
            ;;
    esac

    log "=== done ==="
}

main "$@"
