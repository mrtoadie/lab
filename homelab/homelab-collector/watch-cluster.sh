#!/usr/bin/env bash
#
# watch-cluster.sh
#
# Runs on watcher (OUTSIDE the cluster) and checks via TCP whether the
# Kubernetes API is reachable. Needs NO kubectl and NO credential —
# only bash, jq, git.
#
# KEY DESIGN DECISIONS
#
# 1. The published state is read from origin/<branch>, NOT from the local file.
#    The local file can be stale from an earlier failed run — in that case the
#    script would wrongly assume the error was already published.
#
# 2. NO rebase, NO merge. Both writers (this script and collect.sh on the
#    cluster) regenerate data/cluster.json from scratch on every run. There is
#    nothing to merge — only "whose state wins". So the local checkout is
#    hard-reset to origin, the new content is written on top, committed and
#    pushed. This makes merge conflicts structurally impossible.
#
# 3. Push is retried. If the other writer pushed between our fetch and our
#    push, the push is rejected — we simply fetch again and repeat.
#
# State transitions handled:
#   Cluster UP   + origin shows error  -> recovery written + pushed
#   Cluster UP   + origin shows none   -> nothing to do
#   Cluster DOWN + origin shows none   -> error written + pushed
#   Cluster DOWN + origin shows error  -> nothing to do (no spam)
#
# Usage:
#   cd ~/Projects/mrtoadie.github.io && ~/Projects/lab/homelab/homelab-collector/watch-cluster.sh

set -euo pipefail

# --- Configuration ----------------------------------------------------------
API_HOST="${API_HOST:-192.168.178.210}"
API_PORT="${API_PORT:-6443}"
CLUSTER_JSON="${CLUSTER_JSON:-data/cluster.json}"
REPO_DIR="${REPO_DIR:-$PWD}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_PUSH="${GIT_PUSH:-1}"
TIMEOUT="${TIMEOUT:-5}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

# Defensive: "5s" -> "5", "2.5" -> "2"
TIMEOUT="${TIMEOUT%s}"
TIMEOUT="${TIMEOUT%.*}"
[[ -n "$TIMEOUT" ]] || TIMEOUT=5

log() { printf '%s\n' "$*" >&2; }

# --- Sanity checks ----------------------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "ERROR: $REPO_DIR is not a git repository."
  log "       Start from the website repo or set REPO_DIR."
  exit 2
fi

JSON_PATH="$REPO_DIR/$CLUSTER_JSON"

# --- Clear any stuck rebase/merge state -------------------------------------
for marker in rebase-merge rebase-apply MERGE_HEAD; do
  if [[ -e "$REPO_DIR/.git/$marker" ]]; then
    log "Note: found leftover $marker state — cleaning up"
    git -C "$REPO_DIR" rebase --abort 2>/dev/null || true
    git -C "$REPO_DIR" merge --abort 2>/dev/null || true
    break
  fi
done

# --- Read published state from origin ---------------------------------------
fetch_origin() {
  git -C "$REPO_DIR" fetch origin "$GIT_BRANCH" --quiet 2>/dev/null
}

published_error() {
  git -C "$REPO_DIR" show "origin/$GIT_BRANCH:$CLUSTER_JSON" 2>/dev/null \
    | jq -r 'if .collector_error == null then "" else .collector_error end' \
      2>/dev/null || printf ''
}

# --- Content builders -------------------------------------------------------
# Minimal error payload: no fake data, empty node list.
apply_error_state() {
  local msg="$1" tmp
  tmp="$(mktemp)"
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg err "$msg" \
    '{ timestamp: $ts,
       collector_error: $err,
       nodes: [],
       resource_usage: {},
       pods: { total: 0, running: 0, pending: 0 },
       namespaces: null,
       deployments: null }' >"$tmp"
  mv "$tmp" "$JSON_PATH"
}

# Recovery: keep whatever origin has (possibly real node data written by
# collect.sh in the meantime) and only strip the error flag.
apply_recovery_state() {
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$JSON_PATH" ]] && jq -e . "$JSON_PATH" >/dev/null 2>&1; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'del(.collector_error, .last_success) | .timestamp = $ts' \
      "$JSON_PATH" >"$tmp"
  else
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{ timestamp: $ts,
         collector_error: null,
         nodes: [],
         resource_usage: {},
         pods: { total: 0, running: 0, pending: 0 },
         namespaces: null,
         deployments: null }' >"$tmp"
  fi
  mv "$tmp" "$JSON_PATH"
}

# --- Publish ----------------------------------------------------------------
# kind: "error" | "recovery"
publish_state() {
  local kind="$1" msg="${2:-}" attempt=1

  if [[ "$GIT_PUSH" != "1" ]]; then
    log "GIT_PUSH=0 — no push"
    return 0
  fi

  while (( attempt <= MAX_ATTEMPTS )); do
    if ! fetch_origin; then
      log "ERROR: fetch failed — aborting push"
      return 1
    fi

    # Discard any diverging local commits. The file is regenerated on every
    # run, so local history carries no value — this is what makes conflicts
    # impossible.
    git -C "$REPO_DIR" reset --hard -q "origin/$GIT_BRANCH"

    if [[ "$kind" == "error" ]]; then
      apply_error_state "$msg"
    else
      apply_recovery_state
    fi

    git -C "$REPO_DIR" add "$CLUSTER_JSON"

    if git -C "$REPO_DIR" diff --cached --quiet; then
      log "State on GitHub is already identical — nothing to do"
      return 0
    fi

    git -C "$REPO_DIR" \
      -c user.name="homelab-watcher" \
      -c user.email="homelab-watcher@watcher" \
      commit -q -m "chore(cluster): state update $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if git -C "$REPO_DIR" push -q origin "$GIT_BRANCH"; then
      log "pushed to origin/$GIT_BRANCH"
      return 0
    fi

    log "Push rejected (attempt $attempt/$MAX_ATTEMPTS) — retrying"
    attempt=$((attempt + 1))
  done

  log "ERROR: gave up after $MAX_ATTEMPTS attempts"
  return 1
}

# --- Health check (TCP) -----------------------------------------------------
check_api_health_tcp() {
  timeout "$TIMEOUT" bash -c "echo >/dev/tcp/$API_HOST/$API_PORT" 2>/dev/null \
    && return 0

  if command -v nc >/dev/null; then
    nc -z -w "$TIMEOUT" "$API_HOST" "$API_PORT" 2>/dev/null && return 0
  fi

  return 1
}

# --- Main -------------------------------------------------------------------
log "=== Homelab Cluster Watcher ==="
log "API: $API_HOST:$API_PORT  |  Timeout: ${TIMEOUT}s  |  Repo: $REPO_DIR"

if ! fetch_origin; then
  log "WARNING: fetch from origin failed — using last known state"
fi

pub_err="$(published_error)"
if [[ -n "$pub_err" ]]; then
  log "Published on GitHub: error (\"$pub_err\")"
else
  log "Published on GitHub: no error"
fi

if check_api_health_tcp; then
  desired=""
  log "Cluster reachable (TCP $API_HOST:$API_PORT)."
else
  desired="Kubernetes API Server ($API_HOST:$API_PORT) unreachable (TCP)"
  log "ERROR: cluster unreachable on $API_HOST:$API_PORT"
fi

if [[ "$desired" == "$pub_err" ]]; then
  log "-> Published state is already correct. Nothing to do."
  exit 0
fi

if [[ -n "$desired" ]]; then
  log "-> Transition: OK -> ERROR. Writing and pushing."
  publish_state error "$desired"
else
  log "-> Transition: ERROR -> OK. Writing and pushing."
  publish_state recovery
fi

exit 0
