#!/usr/bin/env bash
set -uo pipefail

# ANSI color codes
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

print_header() {
  echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════"
  echo -e "  $1"
  echo -e "═══════════════════════════════════════${RESET}\n"
}

print_header_second() {
  echo -e "\n${BOLD}${CYAN}| $1 ${CYAN}${RESET}"
}

warn() { echo -e "${YELLOW}⚠ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
info() { echo -e "${DIM}$1${RESET}"; }

###############################################################################
# HELPER FUNCTION - Clean number formatting
###############################################################################
clean_number() {
  local result="${1:-0}"
  result=$(echo "$result" | tr -d '[:space:]')
  [ -z "$result" ] && result=0
  echo "$result"
}

function ClusterInfo {
  print_header_second "CLUSTER INFOS"
  echo -e "${DIM}Context:${RESET} $(kubectl config current-context 2>/dev/null)"
  echo -e "${DIM}K8s Version:${RESET} $(kubectl version 2>/dev/null | grep Server | awk '{print $3}' || echo "unknown")"

  # Initialize global namespace counter early (needed by other functions)
  total_ns=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
  total_ns=$(clean_number "$total_ns")

  echo -e "${DIM}Namespaces:${RESET} $total_ns"
  echo -e "${DIM}Nodes:${RESET} $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Pods Total:${RESET} $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Deployments:${RESET} $(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)"
}

function ControlPlaneHealth {
  print_header_second "CONTROL PLANE COMPONENTS"

  local component status etcd_endpoint etcd_health
  local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")

  for component in "${components[@]}"; do
    status=$(kubectl get pods -n kube-system --field-selector metadata.name~"$component" --no-headers 2>/dev/null | grep -v Running | wc -l)
    status=$(clean_number "$status")
    if [ "$status" -eq 0 ]; then
      success "$component: Healthy"
    else
      error "$component: UNHEALTHY"
    fi
  done

  # Additional etcd health check via etcdctl if available
  if command -v etcdctl &>/dev/null; then
    etcd_endpoint=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [ -n "$etcd_endpoint" ]; then
      etcd_health=$(ETCDCTL_API=3 etcdctl --endpoints="http://$etcd_endpoint:2379" endpoint health 2>&1)
      if echo "$etcd_health" | grep -q "is healthy"; then
        success "etcd: Responsive"
      else
        error "etcd: Health check failed"
      fi
    fi
  fi
}

ClusterInfo
ControlPlaneHealth
