#!/usr/bin/env bash
set -uo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

print_header() {
echo -e "\n${BOLD}${CYAN}| $1 ${CYAN}${RESET}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CLUSTER BASIC INFORMATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "CLUSTER INFO"
echo -e "${DIM}Kontext:${RESET} $(kubectl config current-context 2>/dev/null)"
echo -e "${DIM}K8s Version:${RESET} $(kubectl version 2>/dev/null | grep Server | awk '{print $3}')"
echo -e "${DIM}Namespaces:${RESET} $(kubectl get namespaces --no-headers | wc -l)"
echo -e "${DIM}Nodes:${RESET} $(kubectl get nodes --no-headers | wc -l)"
echo -e "${DIM}Pods total:${RESET} $(kubectl get pods --all-namespaces --no-headers | wc -l)"
echo -e "${DIM}Deployments:${RESET} $(kubectl get deployments --all-namespaces --no-headers | wc -l)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NODE HEALTH & CAPACITY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "NODE HEALTH & CAPACITY"
kubectl get nodes -o wide 2>/dev/null | column -t || echo "${RED}✗ Nodes are unreachable${RESET}"

echo ""
echo -e "${DIM}Node Ressourcen (total):${RESET}"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NODE CONDITIONS (Critical!)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "NODE CONDITIONS (Alerts)"
for node in $(kubectl get nodes -o name); do
  conditions=$(kubectl get "$node" -o jsonpath='{range .status.conditions[?(@.reason=="KubeletReady")]}{.status}{" "}{.message}{"\n"}{end}' 2>/dev/null)
  if [ -n "$conditions" ]; then
    status=$(echo "$conditions" | head -1 | awk '{print $1}')
    if [ "$status" = "True" ]; then
      echo -e "${GREEN}✓ ${node##*/}: Ready${RESET}"
    else
      echo -e "${RED}✗ ${node##*/}: NOT Ready${RESET}"
    fi
  fi
done

# Check Disk Pressure/Memory Pressure
disk_pressure=$(kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name,DISK:.status.conditions[-1:].type" 2>/dev/null | grep DiskPressure | cut -d' ' -f1)
if [ -n "$disk_pressure" ]; then
  echo -e "${RED}⚠ Disk Pressure to: $disk_pressure${RESET}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CRITICAL NAMESPACES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "CRITICAL NAMESPACES"

for ns in kube-system monitoring kube-public; do
  pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
  running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c Running || echo "0")
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)

  echo -e "${GREEN}▶ $ns:${RESET} ${running}/${total} Pods running"

  if [ "$running" != "$total" ]; then
    failed=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v Running | head -3)
    if [ -n "$failed" ]; then
      echo -e "  ${RED}Pods with errors:${RESET}"
      echo "$failed" | sed 's/^/    /'
    fi
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PENDING/FAILED PODS (overall)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "PODS WITH ERRORS"
pending=$(kubectl get pods --all-namespaces --no-headers -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
STATUS:.status.phase,\
REASON:.status.reason 2>/dev/null | grep -E "Pending|Failed|Unknown")

if [ -n "$pending" ]; then
  echo -e "${RED}⚠ Pending/Failed Pods found:${RESET}"
  echo "$pending" | column -t | sed 's/^/  /'
else
  echo -e "${GREEN}✓ No critical Pods${RESET}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STORAGE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "STORAGE"
echo -e "${DIM}Persistent Volumes:${RESET} $(kubectl get pv --no-headers 2>/dev/null | wc -l)"
echo -e "${DIM}Persistent Volume Claims:${RESET} $(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)"

bound=$(kubectl get pv --no-headers 2>/dev/null | grep -c Bound || echo "0")
available=$(kubectl get pv --no-headers 2>/dev/null | grep -c Available || echo "0")

echo -e "${GREEN}  Bound:${RESET} $bound | ${YELLOW}Available:${RESET} $available"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NETWORKING (Ingress/CNI)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "NETWORKING"
echo -e "${DIM}Ingresses:${RESET} $(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l)"
echo -e "${DIM}LoadBalancer Services:${RESET} $(kubectl get svc --all-namespaces --no-headers -o custom-columns="TYPE:.spec.type,IP:.status.loadBalancer.ingress[*].ip" 2>/dev/null | grep LoadBalancer | wc -l)"

# CNI recognize
if kubectl get ds -n kube-system | grep -q cilium; then
  echo -e "${CYAN}CNI:${RESET} Cilium"
elif kubectl get ds -n kube-system | grep -q flannel; then
  echo -e "${CYAN}CNI:${RESET} Flannel"
elif kubectl get ds -n kube-system | grep -q calico; then
  echo -e "${CYAN}CNI:${RESET} Calico"
else
  echo -e "${DIM}CNI:${RESET} unknown"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# QUICK STATS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "QUICK STATS"
kubectl top nodes 2>/dev/null || echo -e "${DIM}metrics-server:${RESET} not available"

echo ""
echo -e "${DIM}Top 5 Pods > CPU:${RESET}"
kubectl top pods --all-namespaces --sort-by=cpu 2>/dev/null | head -6 | tail -5 || echo "  (not available)"

echo ""
echo -e "${DIM}Top 5 Pods > Memory:${RESET}"
kubectl top pods --all-namespaces --sort-by=memory 2>/dev/null | head -6 | tail -5 || echo "  (not available)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SUMMARY BOX
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print_header "SUMMARY"
echo -e "${CYAN}Cluster:${RESET} $(kubectl config current-context 2>/dev/null)"
echo -e "${CYAN}Nodes:${RESET} $(kubectl get nodes --no-headers 2>/dev/null | wc -l) (Ready: $(kubectl get nodes --no-headers | grep -c Ready))"
echo -e "${CYAN}Pods Total:${RESET} $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)"
echo -e "${CYAN}Pods with errors:${RESET} $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -cv Running || echo 0)"
echo -e "${CYAN}Ingresses:${RESET} $(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l)"
echo -e "${CYAN}PVs:${RESET} $bound Bound / $available Available"
echo -e "\n${DIM}Last refresh:${RESET} $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
