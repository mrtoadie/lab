#!/usr/bin/env bash
set -uo pipefail

RESOURCES=(
  pods
  services
  deployments
  daemonsets
  statefulsets
  configmaps
  secrets
  pvc
  ingress
)

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RESET='\033[0m'

if [ -n "${1:-}" ]; then
  namespaces="$1"
else
  namespaces=$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
fi

[ -z "$namespaces" ] && { echo "No namespaces found."; exit 1; }

while IFS= read -r ns; do
  [ -z "$ns" ] && continue
  echo -e "\n${BOLD}${CYAN}| Namespace: ${ns} ${CYAN}${RESET}"

  for resource in "${RESOURCES[@]}"; do
    output=$(kubectl get "$resource" -n "$ns" --no-headers 2>/dev/null) || true

    if [ -n "$output" ]; then
      count=$(echo "$output" | wc -l | tr -d ' ')
      echo -e "${GREEN}▶ ${resource^} (${count})${RESET}"
      echo "$output" | column -t
      echo ""
    fi
  done
done <<< "$namespaces"
