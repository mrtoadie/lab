#!/bin/bash
#
# collect.sh — collect k3s cluster metrics and publish them to GitHub Pages
#
# Runs on the control-plane node (winterfell).
#   * cluster-wide data -> kubectl
#   * host-level data   -> read locally on this node, fetched over SSH elsewhere
#
# Also publishes data/badge.json (shields.io endpoint format) showing the
# live cluster status — embed it in a README with:
#   ![k3s](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/
#          mrtoadie/mrtoadie.github.io/main/data/badge.json)
#
# Requirements: kubectl, jq, curl, base64, ssh, flock, bash >= 4
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
BADGE_FILE="/tmp/badge.json"
REMOTE_PATH="data/cluster.json"
REMOTE_PATH_BADGE="data/badge.json"
LOCK_FILE="/tmp/collect.lock"

# Host-level metrics (disk / temperature / load / uptime) are gathered for
# these nodes. The node running this script is queried locally, the rest
# over SSH. Nodes that are unreachable simply report null.
NODES=(winterfell worker01 worker02 worker03)
LOCAL_HOST="$(hostname -s)"
CONTROL_PLANE="winterfell"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new)
KUBECTL_TIMEOUT="--request-timeout=15s"

# One round trip per node, five lines of output:
#   1. disk usage of / (rootfs) in percent
#   2. disk usage of the USB-SSD mountpoint in percent, or "null"
#   3. raw thermal reading in millidegrees (0 if unavailable)
#   4. 1-minute load average
#   5. uptime in seconds
# NOTE: the USB mountpoint is hardcoded in line 2 of the command below —
# change it there if the mount ever moves. Kept literal on purpose: the
# quoting of CMD_HOSTSTATS is fragile enough without variable splicing.
CMD_HOSTSTATS='root_disk=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc "0-9"); echo "$root_disk"; usb_disk=$(df --output=pcent /media/toadie/clusterdata 2>/dev/null | tail -1 | tr -dc "0-9"); echo "${usb_disk:-null}"; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0; cut -d " " -f1 /proc/loadavg; cut -d. -f1 /proc/uptime'

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# ------------------------------- preflight --------------------------------

# Fail fast with a clear message if a dependency is missing.
for bin in kubectl jq curl base64 ssh flock; do
    command -v "$bin" >/dev/null 2>&1 || { log "✗ missing dependency: $bin"; exit 1; }
done

# Prevent overlapping runs when a timer fires while the previous run is
# still in progress (e.g. after a slow SSH round trip).
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another instance is still running — exiting"
    exit 0
fi

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

    # ------------- nodes: name / role / READY status / version / age --------
    # Built entirely via kubectl -o json + jq instead of hand-concatenated
    # strings. The status is taken explicitly from the Ready condition —
    # .status.conditions[-1] is NOT guaranteed to be the Ready condition,
    # so the old approach could report arbitrary pressure conditions.
    NODES_JSON=$(kubectl get nodes -o json $KUBECTL_TIMEOUT 2>/dev/null \
        | jq -c --arg cp "$CONTROL_PLANE" '
            [.items[] | {
                name: .metadata.name,
                role: (if .metadata.name == $cp then "control-plane" else "worker" end),
                status: ([.status.conditions[] | select(.type == "Ready") | .status] | .[0] // "Unknown"),
                version: .status.nodeInfo.kubeletVersion,
                age: (try (((now - (.metadata.creationTimestamp | fromdateiso8601)) / 86400) | floor | "\(.)d")
                     catch "unknown")
            }]')
    [ -n "$NODES_JSON" ] || NODES_JSON="[]"

    # ------------- one single pods call: totals + running pods per node -----
    # Replaces four separate `kubectl get pods -A` invocations.
    PODS_JSON=$(kubectl get pods -A -o json $KUBECTL_TIMEOUT 2>/dev/null | jq -c '
        {
            total:   length,
            running: [.items[] | select(.status.phase == "Running")] | length,
            pending: [.items[] | select(.status.phase == "Pending")] | length,
            by_node: ([.items[]
                       | select(.status.phase == "Running" and .spec.nodeName != null)
                       | .spec.nodeName]
                      | group_by(.) | map({(.[0]): length}) | add // {})
        }')
    [ -n "$PODS_JSON" ] || PODS_JSON='{"total":0,"running":0,"pending":0,"by_node":{}}'

    # ------------- kubectl top: cpu / memory per node -----------------------
    declare -A K_CPU_PCT K_CPU_CORES K_MEM_PCT K_MEM_RAW

    while read -r n f_cpu f_cpupct f_mem f_mempct; do
        [ -z "$n" ] && continue
        K_CPU_CORES["$n"]="$f_cpu"
        K_CPU_PCT["$n"]="${f_cpupct%\%}"
        K_MEM_RAW["$n"]="$f_mem"
        K_MEM_PCT["$n"]="${f_mempct%\%}"
    done < <(kubectl top nodes --no-headers $KUBECTL_TIMEOUT 2>/dev/null || true)

    # ------------- per-node resource usage ----------------------------------
    # CMD_HOSTSTATS returns five lines per host:
    #   stats[0] rootfs %, stats[1] usb %, stats[2] temp,
    #   stats[3] load, stats[4] uptime
    # Every host object is built with jq and merged into one JSON object —
    # no string concatenation, so a stray quote can never corrupt the file.
    USAGE_JSON="{}"

    local host stats
    local disk_root disk_usb temp_raw load_raw uptime_raw
    local temp load uptime mem_mib cpu_m pods_n host_obj

    for host in "${NODES[@]}"; do
        mapfile -t stats < <(run_on "$host" "$CMD_HOSTSTATS")
        [ "${#stats[@]}" -eq 5 ] || stats=("" "" "" "" "")

        disk_root=$(int_or_null "${stats[0]:-}")
        disk_usb=$(int_or_null "${stats[1]:-}")
        temp_raw="${stats[2]:-}"
        load_raw="${stats[3]:-}"
        uptime_raw="${stats[4]:-}"

        load=$(num_or_null "$load_raw")
        uptime=$(int_or_null "$uptime_raw")

        if is_int "$temp_raw" && [ "$temp_raw" -gt 0 ]; then
            temp=$(jq -n --argjson t "$temp_raw" '$t / 1000')
        else
            temp="null"
        fi

        mem_mib=$(to_mib "${K_MEM_RAW[$host]:-}")
        cpu_m=$(to_millicores "${K_CPU_CORES[$host]:-}")
        pods_n=$(int_or_null "$(jq -r --arg h "$host" '.by_node[$h] // "null"' <<<"$PODS_JSON")")

        host_obj=$(jq -n \
            --arg h "$host" \
            --argjson cpu_pct  "$(int_or_null "${K_CPU_PCT[$host]:-}")" \
            --argjson cpu_m    "$cpu_m" \
            --argjson mem_pct  "$(int_or_null "${K_MEM_PCT[$host]:-}")" \
            --argjson mem_mib  "$mem_mib" \
            --argjson disk     "$disk_root" \
            --argjson disk_usb "$disk_usb" \
            --argjson temp     "$temp" \
            --argjson load     "$load" \
            --argjson uptime   "$uptime" \
            --argjson pods     "$pods_n" \
            '{($h): {
                cpu_percent:   $cpu_pct,
                cpu_millicores: $cpu_m,
                mem_percent:   $mem_pct,
                mem_mib:       $mem_mib,
                disk_percent:  $disk,
                disk_usb:      $disk_usb,
                temp_c:        $temp,
                load1:         $load,
                uptime_s:      $uptime,
                pods:          $pods
            }}')
        USAGE_JSON=$(jq -c --argjson o "$host_obj" '. + $o' <<<"$USAGE_JSON")
    done

    # ------------- remaining cluster-wide counters ---------------------------
    NS_COUNT=$(kubectl get namespaces -o name $KUBECTL_TIMEOUT 2>/dev/null | wc -l | tr -d ' ')
    DEPLOY_COUNT=$(kubectl get deployments -A -o name $KUBECTL_TIMEOUT 2>/dev/null | wc -l | tr -d ' ')
    SVC_COUNT=$(kubectl get services -A -o name $KUBECTL_TIMEOUT 2>/dev/null | wc -l | tr -d ' ')

    # ------------- write the payload (schema unchanged for the dashboard) ----
    jq -n \
        --arg ts "$TIMESTAMP" \
        --arg col "$LOCAL_HOST" \
        --argjson nodes "$NODES_JSON" \
        --argjson usage "$USAGE_JSON" \
        --argjson pods "$PODS_JSON" \
        --argjson ns  "${NS_COUNT:-0}" \
        --argjson dep "${DEPLOY_COUNT:-0}" \
        --argjson svc "${SVC_COUNT:-0}" \
        '{
            timestamp:    $ts,
            collected_on: $col,
            nodes:        $nodes,
            resource_usage: $usage,
            pods: { total: $pods.total, running: $pods.running, pending: $pods.pending },
            namespaces:  $ns,
            deployments: $dep,
            services:    $svc,
            source: "winterfell-k3s-cluster"
        }' > "$DATA_FILE"

    log "✓ wrote $DATA_FILE"
}

# -------------------------------- badge -----------------------------------

# shields.io endpoint format. "status" is now reliably the Ready condition,
# so counting "True" values is safe.
write_badge() {
    local total up color msg
    total=${#NODES[@]}
    up=$(jq '[.nodes[] | select(.status == "True")] | length' "$DATA_FILE" 2>/dev/null || echo 0)

    if   [ "$total" -gt 0 ] && [ "$up" -eq "$total" ]; then
        color="green";  msg="$up/$total nodes online"
    elif [ "$up" -gt 0 ]; then
        color="yellow"; msg="$up/$total nodes online"
    else
        color="red";    msg="cluster down"
    fi

    jq -n --arg m "$msg" --arg c "$color" \
        '{schemaVersion:1, label:"k3s", message:$m, color:$c}' > "$BADGE_FILE"

    log "✓ wrote $BADGE_FILE ($msg)"
}

# ------------------------------ publishing --------------------------------

# Push one local file to one path in the repo. Called once per file, so
# cluster.json and badge.json share the exact same create/update logic.
push_file() {
    local file="$1" remote="$2" msg="$3"
    local resp http sha content payload

    if ! jq -e . "$file" >/dev/null 2>&1; then
        log "✗ $file is not valid JSON — upload aborted"
        return 1
    fi

    resp=$(mktemp)

    # Get current sha. Only 404 means "file not there yet"; any other error
    # (rate limit, bad token, network) aborts loudly instead of silently
    # falling into the create path.
    http=$(curl -s -o "$resp" -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_USER/$REPO/contents/$remote")

    if [ "$http" = "200" ]; then
        sha=$(jq -r '.sha // empty' "$resp")
    elif [ "$http" = "404" ]; then
        log "  $remote does not exist yet — will create"
        sha=""
    else
        log "✗ GET $remote failed (HTTP $http): $(jq -r '.message // "?"' "$resp" 2>/dev/null)"
        rm -f "$resp"
        return 1
    fi

    content=$(base64 -w0 "$file")
    if [ -n "$sha" ]; then
        payload=$(jq -n --arg m "$msg" --arg c "$content" --arg s "$sha" --arg b "$BRANCH" \
                    '{message:$m, content:$c, sha:$s, branch:$b}')
    else
        payload=$(jq -n --arg m "$msg" --arg c "$content" --arg b "$BRANCH" \
                    '{message:$m, content:$c, branch:$b}')
    fi

    http=$(curl -s -o "$resp" -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_USER/$REPO/contents/$remote" \
        -d "$payload")

    if [ "$http" = "200" ] || [ "$http" = "201" ]; then
        log "✓ committed $(jq -r '.commit.sha[0:8] // "?"' "$resp") -> $remote"
    else
        log "✗ PUT $remote failed (HTTP $http): $(jq -r '.message // "?"' "$resp" 2>/dev/null)"
        rm -f "$resp"
        return 1
    fi

    rm -f "$resp"
}

# ---------------------------------- main ----------------------------------

main() {
    if [ ! -r "$TOKEN_FILE" ]; then
        log "✗ token file not readable: $TOKEN_FILE"
        exit 1
    fi
    # Strip whitespace/newlines so a stray blank line in the token file
    # cannot silently corrupt the Authorization header.
    TOKEN=$(tr -d ' \t\r\n' < "$TOKEN_FILE")
    if [ -z "$TOKEN" ]; then
        log "✗ token file is empty: $TOKEN_FILE"
        exit 1
    fi
    if ! [[ "$TOKEN" =~ ^(gh[pousr]_|github_pat_|[a-f0-9]{40}) ]]; then
        log "  note: token format looks unusual — proceeding anyway"
    fi
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true

    collect_cluster_data
    write_badge

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry run — skipping upload"
        echo "--- cluster.json ---"
        jq '.' "$DATA_FILE"
        echo "--- badge.json ---"
        jq '.' "$BADGE_FILE"
    else
        push_file "$DATA_FILE"  "$REMOTE_PATH"       "metrics: $TIMESTAMP" \
            || log "(cluster.json upload failed — badge still tried)"
        push_file "$BADGE_FILE" "$REMOTE_PATH_BADGE" "badge:   $TIMESTAMP" \
            || log "(badge.json upload failed)"
    fi

    log "=== done ==="
}

main "$@"
