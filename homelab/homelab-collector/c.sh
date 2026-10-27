#!/bin/bash
#
# collect.sh — collect k3s cluster metrics and publish them to GitHub Pages
#
# Runs on the control-plane node (winterfell).
#   * cluster-wide data -> kubectl
#   * host-level data   -> read locally on this node, fetched over SSH elsewhere
#
# Requirements: kubectl, jq, curl, base64, ssh, bash >= 4
#
# Usage:
#   ./collect.sh              collect and publish
#   ./collect.sh --dry-run    collect only, write /tmp/cluster.json, no upload
#
set -euo pipefail

# ----------------------------- configuration ------------------------------

GITHUB_USER="mrtoadie"
REPO="mrtoadie.github.io"
BRANCH="main"

TOKEN_FILE="$HOME/.github_token"
DATA_FILE="/tmp/cluster.json"
REMOTE_PATH="data/cluster.json"

# Host-level metrics (disk / temperature / load / uptime) are gathered for
# these nodes. The node running this script is queried locally, the rest
# over SSH. Nodes that are unreachable simply report null.
NODES=(winterfell worker01 worker02 worker03)
LOCAL_HOST="$(hostname -s)"
CONTROL_PLANE="winterfell"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new)

# One round trip per node, four lines of output:
#   1. disk usage of / in percent
#   2. raw thermal reading in millidegrees (0 if unavailable)
#   3. 1-minute load average
#   4. uptime in seconds
# NEW (robust):
CMD_HOSTSTATS=$(cat <<'HEREDOC'
# Line 1: disk percent (integer only)
df --output=pcent / 2>/dev/null | awk '/\/$/{gsub(/[^0-9]/,"",$2); print $2+0; exit}' || echo 0
# Line 2: temperature in millidegrees
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0
elif command -v vcgencmd &>/dev/null; then
    vcgencmd measure_temp 2>/dev/null | sed "s/temp=//;s/'C//" | awk '{print int($1*1000)}' || echo 0
else
    echo 0
fi
# Line 3: 1-min load average
awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
# Line 4: uptime seconds
awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0
HEREDOC
)

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# -------------------------------- helpers ---------------------------------

# Run a shell fragment on $1 — locally if it is this host, otherwise via SSH.
run_on() {
    local host="$1" cmd="$2"
    if [ "$host" = "$LOCAL_HOST" ]; then
        bash -c "$cmd" 2>/dev/null || true
    else
        ssh "${SSH_OPTS[@]}" "$host" "$cmd" 2>/dev/null || true
    fi
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# Emit the value if usable, otherwise the JSON literal null.
int_or_null() { if is_int "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi; }
num_or_null() { if is_num "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi; }

# "3714Mi" / "2Gi" / "512Ki" -> integer MiB, or null
to_mib() {
    local v="${1:-}"
    case "$v" in
        *Gi) if is_int "${v%Gi}"; then printf '%s' "$(( ${v%Gi} * 1024 ))"; return; fi ;;
        *Mi) if is_int "${v%Mi}"; then printf '%s' "${v%Mi}"; return; fi ;;
        *Ki) if is_int "${v%Ki}"; then printf '%s' "$(( ${v%Ki} / 1024 ))"; return; fi ;;
    esac
    printf 'null'
}

# "507m" -> 507 ; "2" -> 2000 ; anything else -> null
to_millicores() {
    local v="${1:-}"
    case "$v" in
        *m) if is_int "${v%m}"; then printf '%s' "${v%m}"; return; fi ;;
        "") ;;
        *)  if is_int "$v"; then printf '%s' "$(( v * 1000 ))"; return; fi ;;
    esac
    printf 'null'
}

# ------------------------------- collection -------------------------------

collect_cluster_data() {
    log "Collecting cluster metrics…"

    # ---------------- nodes: name / role / status / version ----------------
    local nodes_json="[" sep="" name status version role
    while IFS= read -r line; do
        name=$(awk '{print $1}' <<<"$line")
        status=$(awk '{print $2}' <<<"$line")
        version=$(awk '{print $3}' <<<"$line")
        [ -z "$name" ] && continue

        if [ "$name" = "$CONTROL_PLANE" ]; then role="control-plane"; else role="worker"; fi

        nodes_json+="${sep}{\"name\":\"${name}\",\"role\":\"${role}\",\"status\":\"${status}\",\"version\":\"${version}\"}"
        sep=","
    done < <(kubectl get nodes \
                -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].status,VERSION:.status.nodeInfo.kubeletVersion \
                --no-headers 2>/dev/null || true)
    nodes_json+="]"

    # ---------------- kubectl top: cpu / memory per node ----------------
    declare -A K_CPU_PCT K_CPU_CORES K_MEM_PCT K_MEM_RAW

    while read -r n f_cpu f_cpupct f_mem f_mempct; do
        [ -z "$n" ] && continue
        K_CPU_CORES["$n"]="$f_cpu"
        K_CPU_PCT["$n"]="${f_cpupct%\%}"
        K_MEM_RAW["$n"]="$f_mem"
        K_MEM_PCT["$n"]="${f_mempct%\%}"
    done < <(kubectl top nodes --no-headers 2>/dev/null || true)

    # ---------------- running pods per node ----------------
    # Single kubectl round trip, grouped with awk. Pending pods without a
    # node assignment fall through the empty-name guard.
    declare -A K_PODS
    while read -r count node; do
        [ -z "${node:-}" ] && continue
        K_PODS["$node"]="$count"
    done < <(kubectl get pods -A \
                --field-selector=status.phase=Running \
                -o custom-columns=NODE:.spec.nodeName \
                --no-headers 2>/dev/null \
             | awk 'NF { c[$1]++ } END { for (n in c) print c[n], n }')

    # ---------------- per-node resource usage ----------------
    local usage_json="{" usep=""
    local host stats disk_raw temp_raw load_raw uptime_raw
    local disk temp load uptime mem_mib cpu_m pods_n

    for host in "${NODES[@]}"; do
        mapfile -t stats < <(run_on "$host" "$CMD_HOSTSTATS")
        disk_raw="${stats[0]:-}"
        temp_raw="${stats[1]:-}"
        load_raw="${stats[2]:-}"
        uptime_raw="${stats[3]:-}"

        disk=$(int_or_null "$disk_raw")
        load=$(num_or_null "$load_raw")
        uptime=$(int_or_null "$uptime_raw")

        if is_int "$temp_raw" && [ "$temp_raw" -gt 0 ]; then
    # Use bc or awk for decimal precision
    temp=$(awk "BEGIN {printf \"%.1f\", $temp_raw/1000}")
else
    temp="null"
fi

        mem_mib=$(to_mib "${K_MEM_RAW[$host]:-}")
        cpu_m=$(to_millicores "${K_CPU_CORES[$host]:-}")
        pods_n=$(int_or_null "${K_PODS[$host]:-}")

        usage_json+="${usep}\"${host}\":{"
        usage_json+="\"cpu_percent\":$(int_or_null "${K_CPU_PCT[$host]:-}"),"
        usage_json+="\"cpu_millicores\":${cpu_m},"
        usage_json+="\"mem_percent\":$(int_or_null "${K_MEM_PCT[$host]:-}"),"
        usage_json+="\"mem_mib\":${mem_mib},"
        usage_json+="\"disk_percent\":${disk},"
        usage_json+="\"temp_c\":${temp},"
        usage_json+="\"load1\":${load},"
        usage_json+="\"uptime_s\":${uptime},"
        usage_json+="\"pods\":${pods_n}"
        usage_json+="}"
        usep=","
    done
    usage_json+="}"

    # ---------------- cluster-wide counters ----------------
    local pods_total pods_running pods_pending ns_count deploy_count svc_count

    pods_total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_running=$(kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_pending=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ns_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    deploy_count=$(kubectl get deployments -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    svc_count=$(kubectl get services -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

    # ---------------- write the payload ----------------
    cat > "$DATA_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "collected_on": "$LOCAL_HOST",
  "nodes": $nodes_json,
  "resource_usage": $usage_json,
  "pods": {
    "total": ${pods_total:-0},
    "running": ${pods_running:-0},
    "pending": ${pods_pending:-0}
  },
  "namespaces": ${ns_count:-0},
  "deployments": ${deploy_count:-0},
  "services": ${svc_count:-0},
  "source": "winterfell-k3s-cluster"
}
EOF

    log "✓ wrote $DATA_FILE"
}

# -------------------------------- publishing ------------------------------

push_to_github() {
    log "Publishing to GitHub…"

    if ! jq -e . "$DATA_FILE" >/dev/null 2>&1; then
        log "✗ $DATA_FILE is not valid JSON — upload aborted"
        return 1
    fi

    local content sha payload
    content=$(base64 -w0 "$DATA_FILE")

    sha=$(curl -sf -H "Authorization: Bearer $TOKEN" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com/repos/$GITHUB_USER/$REPO/contents/$REMOTE_PATH" \
           | jq -r '.sha // empty' || true)

    if [ -z "$sha" ]; then
        log "  file does not exist yet — creating"
        payload=$(jq -n --arg m "metrics: $TIMESTAMP" --arg c "$content" --arg b "$BRANCH" \
                    '{message:$m, content:$c, branch:$b}')
    else
        log "  updating existing file (sha ${sha:0:8})"
        payload=$(jq -n --arg m "metrics: $TIMESTAMP" --arg c "$content" --arg s "$sha" --arg b "$BRANCH" \
                    '{message:$m, content:$c, sha:$s, branch:$b}')
    fi

    if curl -sf -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_USER/$REPO/contents/$REMOTE_PATH" \
        -d "$payload" | jq -r '"✓ committed " + (.commit.sha[0:8] // "?")'; then
        log "✓ published"
    else
        log "✗ upload failed — check token permissions and rate limit"
        return 1
    fi
}

# ---------------------------------- main ----------------------------------

main() {
    if [ ! -r "$TOKEN_FILE" ]; then
        log "✗ token file not readable: $TOKEN_FILE"
        exit 1
    fi
    TOKEN=$(<"$TOKEN_FILE")

    collect_cluster_data

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry run — skipping upload"
        jq '.' "$DATA_FILE"
    else
        push_to_github
    fi

    log "=== done ==="
}

main "$@"
