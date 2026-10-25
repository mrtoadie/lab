#!/usr/bin/env bash
#
# watch-cluster.sh
#
# Läuft auf watcher (AUSSERHALB des Clusters) und prüft per HTTP, ob die
# Kubernetes-API erreichbar ist. Braucht KEIN kubectl und KEIN Credential —
# nur curl, jq, git und optional das CA-Zertifikat (ca.pem).
#
# Cluster erreichbar  -> Skript tut nichts. collect.sh im Cluster schreibt die
#                        echten Daten und entfernt dabei collector_error.
# Cluster NICHT da    -> Skript schreibt data/cluster.json mit collector_error
#                        und pusht nach GitHub. Frontend zeigt roten Banner.
#
# FIXES gegenüber der vorherigen Version:
#   1. TIMEOUT war "5s" — curl akzeptiert bei --max-time KEIN Suffix, nur
#      Sekunden mit Dezimalpunkt ("5" oder "2.5"). Das führte zu Exit-Code 2
#      ("expected a proper numerical parameter") und damit zu einem
#      Fehlalarm, obwohl der Cluster lief. Jetzt: reine Zahl, plus
#      defensive Bereinigung falls doch ein "s" in der Variable steht.
#   2. Kein Fallback mehr bei fehlgeschlagener CA-Verifikation. Jetzt wird
#      nach einem Fehlschlag mit CA ein zweiter Versuch ohne Verifikation
#      unternommen (mit Warnung im Log).
#   3. curl-Exit-Code wird geloggt, damit Fehlalarme künftig sofort
#      unterscheidbar sind: 2 = Syntaxfehler, 6 = DNS, 7 = Connection refused,
#      28 = Timeout, 60 = TLS-Verifikation.
#
# Aufruf:
#   ./watch-cluster.sh
#
# Konfiguration per Environment, z.B.:
#   API_SERVER=https://192.168.178.210:6443 TIMEOUT=3 ./watch-cluster.sh

set -euo pipefail

# --- Konfiguration ----------------------------------------------------------
API_SERVER="${API_SERVER:-https://192.168.178.210:6443}"
CLUSTER_JSON="${CLUSTER_JSON:-data/cluster.json}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/homelab-collector}"
LAST_ERROR_FILE="$STATE_DIR/last_error_push"
CA_FILE="${CA_FILE:-$HOME/Projects/lab/homelab/homelab-collector/ca.pem}"
GIT_BRANCH="${GIT_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-$PWD}"
GIT_PUSH="${GIT_PUSH:-1}"
TIMEOUT="${TIMEOUT:-5}"
ERROR_COOLDOWN="${ERROR_COOLDOWN:-300}"

# Defensive: falls jemand "5s" setzt, das Suffix entfernen.
TIMEOUT="${TIMEOUT%s}"

log() { printf '%s\n' "$*" >&2; }

# --- Git --------------------------------------------------------------------
push_if_changed() {
  if [[ "$GIT_PUSH" != "1" ]]; then
    log "GIT_PUSH=0 — kein Push"
    return 0
  fi
  if ! command -v git >/dev/null; then
    log "git nicht gefunden — kein Push"
    return 0
  fi

  git -C "$REPO_DIR" add "$CLUSTER_JSON"

  if git -C "$REPO_DIR" diff --cached --quiet; then
    log "keine Aenderung an $CLUSTER_JSON — kein Commit"
    return 0
  fi

  if ! git -C "$REPO_DIR" pull --rebase origin "$GIT_BRANCH"; then
    log "FEHLER: pull --rebase fehlgeschlagen — Push abgebrochen"
    git -C "$REPO_DIR" rebase --abort 2>/dev/null || true
    return 1
  fi

  git -C "$REPO_DIR" \
    -c user.name="homelab-watcher" \
    -c user.email="homelab-watcher@watcher" \
    commit -m "chore(cluster): error state $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if ! git -C "$REPO_DIR" push origin "$GIT_BRANCH"; then
    log "FEHLER: push abgelehnt — versuche es beim naechsten Lauf erneut"
    return 1
  fi

  log "gepusht nach origin/$GIT_BRANCH"
}

# --- Fehlerzustand schreiben -------------------------------------------------
write_error_file() {
  local err_msg="$1"
  local tmp

  mkdir -p "$(dirname "$CLUSTER_JSON")" "$STATE_DIR"
  tmp="$(mktemp)"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg err "$err_msg" \
    '{ timestamp: $ts,
       collector_error: $err,
       nodes: [],
       resource_usage: {},
       pods: { total: 0, running: 0, pending: 0 },
       namespaces: null,
       deployments: null }' >"$tmp"

  mv "$tmp" "$CLUSTER_JSON"
  push_if_changed

  date -u +%Y-%m-%dT%H:%M:%SZ >"$LAST_ERROR_FILE"
  log "Fehlerzustand geschrieben und gepusht: $err_msg"
}

# --- Health-Check ------------------------------------------------------------
# /version ist ein anonym zugänglicher Endpunkt (kein Token nötig).
# /readyz würde 401 liefern, weil es Authentifizierung verlangt.
curl_exit_hint() {
  case "$1" in
    2)  echo "curl-Syntaxfehler (Argument ungültig)" ;;
    6)  echo "DNS-Auflösung fehlgeschlagen" ;;
    7)  echo "Verbindung abgelehnt (Host down / Port zu)" ;;
    28) echo "Timeout" ;;
    35) echo "TLS-Handshake fehlgeschlagen" ;;
    60) echo "TLS-Zertifikat nicht verifizierbar" ;;
    *)  echo "curl-Exit $1" ;;
  esac
}

check_api_health() {
  local rc=0

  if [[ -f "$CA_FILE" ]]; then
    curl -sf --max-time "$TIMEOUT" --cacert "$CA_FILE" \
      "${API_SERVER}/version" >/dev/null 2>&1 || rc=$?

    if (( rc == 0 )); then
      return 0
    fi

    # Fallback: ohne Verifikation erneut versuchen. Deckt den Fall ab, dass
    # ca.pem nicht zum aktuellen Server-Cert passt (z.B. k3s-Zertifikat
    # rotiert) — der Cluster ist dann trotzdem erreichbar.
    log "CA-Check fehlgeschlagen ($(curl_exit_hint "$rc")) — Retry ohne Verifikation"
    curl -sfk --max-time "$TIMEOUT" \
      "${API_SERVER}/version" >/dev/null 2>&1 || {
        rc=$?
        log "Auch ohne Verifikation fehlgeschlagen: $(curl_exit_hint "$rc")"
        return 1
      }
    log "Erreichbar, aber Zertifikat nicht verifizierbar — ca.pem pruefen"
    return 0
  fi

  log "WARNUNG: $CA_FILE fehlt — pruefe ohne Zertifikatsverifikation"
  curl -sfk --max-time "$TIMEOUT" \
    "${API_SERVER}/version" >/dev/null 2>&1 || {
      rc=$?
      log "Fehlgeschlagen: $(curl_exit_hint "$rc")"
      return 1
    }
  return 0
}

# --- Main --------------------------------------------------------------------
log "=== Homelab Cluster Watcher ==="
log "API: $API_SERVER  |  Timeout: ${TIMEOUT}s  |  CA: $CA_FILE"

mkdir -p "$STATE_DIR"

if check_api_health; then
  log "Cluster erreichbar (/version -> HTTP 200). Nichts zu tun."
  # Cooldown zurücksetzen, damit ein späterer Ausfall sofort gemeldet wird.
  rm -f "$LAST_ERROR_FILE"
  exit 0
fi

log "FEHLER: Cluster antwortet nicht auf ${API_SERVER}/version"

# Nicht spammen: pro Ausfall nur ein Fehler-Commit.
if [[ -f "$LAST_ERROR_FILE" ]]; then
  last_err_time="$(cat "$LAST_ERROR_FILE")"
  now_ts="$(date +%s)"
  err_ts="$(date -d "$last_err_time" +%s 2>/dev/null || echo 0)"
  diff_sec=$(( now_ts - err_ts ))

  if (( diff_sec < ERROR_COOLDOWN )); then
    log "Ausfall bereits vor ${diff_sec}s dokumentiert — kein weiterer Push"
    exit 1
  fi
fi

write_error_file "Kubernetes API Server (${API_SERVER}/version) nicht erreichbar"
exit 1
