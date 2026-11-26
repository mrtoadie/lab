#!/usr/bin/env bash
#
# Kubernetes Production Readiness Check
# Author: toadie
# Description: Comprehensive cluster health and production readiness assessment.
#              Fixed & streamlined revision of cProduction.sh.
#
# Usage:
#   ./cProduction.sh            # run full check
#   ./cProduction.sh -e        # additionally print emergency kubectl cheat sheet
#
set -uo pipefail

###############################################################################
# GLOBAL STATE
###############################################################################
declare -i pdb_count=0
declare -i hpa_count=0
declare -i np_count=0
declare -i velero_deployed=0
declare -i admission_labeled=0
declare -i argocd_installed=0
declare -i flux_installed=0
declare -i quota_total=0
declare -i total_ns=0
declare privileged=""

# ANSI color codes
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

# Disable colors when output is redirected to a file
if [ -t 1 ]; then
  BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'; RESET='\033[0m'
else
  BOLD=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

print_header() {
  echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════"
  echo -e "  $1"
  echo -e "═══════════════════════════════════════${RESET}\n"
}

print_header_second() {
  echo -e "\n${BOLD}${CYAN}| $1 ${RESET}"
}

warn()    { echo -e "${YELLOW}⚠ $1${RESET}"; }
error()   { echo -e "${RED}✗ $1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
info()    { echo -e "${DIM}$1${RESET}"; }

# Strip whitespace, coerce empty to 0 so arithmetic never chokes
clean_number() {
  local result="${1:-0}"
  result=$(echo "$result" | tr -d '[:space:]')
  [ -z "$result" ] && result=0
  echo "$result"
}

###############################################################################
# CLI FLAGS
###############################################################################
SHOW_EMERGENCY=0
for arg in "$@"; do
  case "$arg" in
    -e|--emergency) SHOW_EMERGENCY=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)"
      exit 1
      ;;
  esac
done

###############################################################################
# PREFLIGHT - fail fast instead of printing 50 empty sections
###############################################################################
if ! kubectl get --raw /readyz >/dev/null 2>&1; then
  echo -e "${RED}✗ Cluster unreachable (kubectl get --raw /readyz failed)${RESET}"
  echo -e "${DIM}  Check kubeconfig context or cluster availability first.${RESET}"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${YELLOW}⚠ jq not found in PATH - several sections will be skipped or inaccurate${RESET}"
fi

###############################################################################
# CLUSTER BASICS (merged: version via /version, CNI detection, allocatable)
###############################################################################
function ClusterInfo {
  print_header_second "CLUSTER INFOS"

  echo -e "${DIM}Context:${RESET} $(kubectl config current-context 2>/dev/null)"
  # 'kubectl version' output format changed across releases;
  # querying /version directly is stable and deprecation-free
  echo -e "${DIM}K8s Version:${RESET} $(kubectl get --raw /version 2>/dev/null | jq -r '.gitVersion // "unknown"')"

  # Initialize global namespace counter early (needed by later functions)
  total_ns=$(clean_number "$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)")

  echo -e "${DIM}Namespaces:${RESET} $total_ns"
  echo -e "${DIM}Nodes:${RESET} $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Pods Total:${RESET} $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Deployments:${RESET} $(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)"

  # CNI detection via kube-system DaemonSets
  local ds_list cni="unknown"
  ds_list=$(kubectl get ds -n kube-system --no-headers 2>/dev/null)
  if   echo "$ds_list" | grep -q cilium; then cni="Cilium"
  elif echo "$ds_list" | grep -q flannel; then cni="Flannel"
  elif echo "$ds_list" | grep -q calico;  then cni="Calico"
  fi
  echo -e "${DIM}CNI:${RESET} $cni"

  # Allocatable resources per node (single API call)
  echo -e "${DIM}Allocatable (per node):${RESET}"
  kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory' \
    --no-headers 2>/dev/null | sed 's/^/  /'
}

###############################################################################
# HELM VERSION CHECK
###############################################################################
function HelmInfo {
  if command -v helm &>/dev/null; then
    local helm_ver repo_count
    helm_ver=$(helm version --short 2>/dev/null || echo "unknown")
    success "Helm Client: $helm_ver"
    repo_count=$(helm repo list 2>/dev/null | tail -n +2 | wc -l || echo "0")
    info "Helm Repositories: $(clean_number "$repo_count")"
  else
    info "Helm CLI not in PATH"
  fi
}

###############################################################################
# CONTROL PLANE COMPONENTS HEALTH
# Uses /readyz?verbose (stable across k3s, kubeadm, managed clusters).
# IMPORTANT: 'not found in the output' is NOT the same as 'failing'.
# Modern API servers only list the checks they actually run - e.g. standalone
# 'scheduler'/'controller-manager' entries disappeared with the deprecated
# ComponentStatus API. Overall readiness is proven by the /readyz preflight,
# so missing entries are reported as informational, not unhealthy.
###############################################################################
function ControlPlaneHealth {
  print_header_second "CONTROL PLANE COMPONENTS"

  local readyz failures component
  readyz=$(kubectl get --raw '/readyz?verbose' 2>/dev/null)

  if [ -z "$readyz" ]; then
    warn "/readyz?verbose not reachable - skipping component checks"
    return
  fi

  for component in etcd scheduler controller-manager; do
    if echo "$readyz" | grep -Eq "^\[\+\].*${component}.*ok"; then
      success "$component: Healthy"
    elif echo "$readyz" | grep -Eq "^\[-\].*${component}"; then
      error "$component: UNHEALTHY"
    else
      # Check not present in this cluster/version - not an error condition,
      # since the overall /readyz preflight already succeeded
      info "$component: not reported by /readyz (not an error)"
    fi
  done

  # Show every failing individual check, if any
  failures=$(echo "$readyz" | grep -E '^\[-\]')
  if [ -n "$failures" ]; then
    warn "Failing individual health checks:"
    echo "$failures" | sed 's/^/  /'
  fi
}

###############################################################################
# CERTIFICATE EXPIRATION CHECK
###############################################################################
function CertificateExpiration {
  print_header_second "CERTIFICATES & TLS"

  local k3s_cert_path="/etc/rancher/k3s/server/tls/server.crt"
  local expiry_date api_cert end_date expiry_epoch current_epoch days_until
  local warning_certs="" expired_certs=""
  local ns name cert_data

  # 1. k3s API Server certificate directly from the filesystem
  if [ -f "$k3s_cert_path" ] && [ -r "$k3s_cert_path" ]; then
    expiry_date=$(openssl x509 -in "$k3s_cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry_date" ]; then
      echo -e "${CYAN}API Server (k3s):${RESET} Expires $expiry_date"
    fi
  else
    # Fallback for kubeadm-style clusters
    api_cert=$(kubectl get secret -n kube-system kube-api-serving-cert -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "")
    if [ -n "$api_cert" ]; then
      expiry_date=$(echo "$api_cert" | cut -d= -f2)
      echo -e "${CYAN}API Server:${RESET} Expires $expiry_date"
    else
      info "API Server Certificate cannot be verified (kubeadm/cert-manager or no root access)"
    fi
  fi

  # 2. Count TLS secrets (single API call)
  local tls_certs
  tls_certs=$(clean_number "$(kubectl get secrets --all-namespaces --no-headers 2>/dev/null | grep -c 'kubernetes.io/tls')")
  info "TLS Secrets found: $tls_certs"

  # 3. Check certificate expiration using while-read (safe with base64 blobs)
  while IFS='|' read -r ns name cert_data; do
    [ -z "${cert_data:-}" ] && continue
    [ "$cert_data" = "null" ] && continue
    end_date=$(echo "$cert_data" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [ -n "$end_date" ]; then
      expiry_epoch=$(date -d "$end_date" +%s 2>/dev/null)
      current_epoch=$(date +%s)

      if [ -n "$expiry_epoch" ]; then
        days_until=$(( (expiry_epoch - current_epoch) / 86400 ))
        if [ "$days_until" -lt 30 ] && [ "$days_until" -gt 0 ]; then
          warning_certs="${warning_certs}${ns}/${name} (${days_until} days)\n"
        elif [ "$days_until" -le 0 ]; then
          expired_certs="${expired_certs}${ns}/${name} EXPIRED!\n"
        fi
      fi
    fi
  done < <(kubectl get secrets --all-namespaces -o json 2>/dev/null | jq -r '
    .items[] | select(.type=="kubernetes.io/tls") |
    "\(.metadata.namespace)|\(.metadata.name)|\(.data["tls.crt"] // "")"'
  )

  if [ -n "$expired_certs" ]; then
    error "EXPIRED certificates found:"
    echo -e "$expired_certs" | sed 's/^/  /'
  fi

  if [ -n "$warning_certs" ]; then
    warn "Certificates expiring soon (< 30 days):"
    echo -e "$warning_certs" | sed 's/^/  /'
  fi
}

###############################################################################
# RESOURCE QUOTAS & LIMIT RANGES
# Batched: one API call for quotas across all namespaces instead of two per
# namespace. On a Pi cluster this noticeably cuts runtime.
###############################################################################
function ResourceQuotasLimits {
  print_header_second "RESOURCE QUOTAS & LIMIT RANGES"

  local quotas limitranges_total
  quotas=$(kubectl get resourcequota --all-namespaces \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,USED:.status.used,HARD:.status.hard' \
    --no-headers 2>/dev/null)
  quota_total=$(clean_number "$(echo "$quotas" | grep -c .)")
  limitranges_total=$(clean_number "$(kubectl get limitrange --all-namespaces --no-headers 2>/dev/null | wc -l)")

  info "ResourceQuotas: $quota_total | LimitRanges: $limitranges_total"

  if [ "$quota_total" -gt 0 ]; then
    echo "$quotas" | sed 's/^/  /'
  fi

  # Pods without resource requests/limits
  echo ""
  info "Pods without resource requests or limits:"
  local no_resources
  no_resources=$(kubectl get pods --all-namespaces -o custom-columns=\
  NS:.metadata.namespace,\
  POD:.metadata.name,\
  HAS_REQUESTS:.spec.containers[*].resources.requests,\
  HAS_LIMITS:.spec.containers[*].resources.limits \
  --no-headers 2>/dev/null | awk '$3=="" || $4==""' | head -10)

  if [ -n "$no_resources" ]; then
    warn "$(clean_number "$(echo "$no_resources" | wc -l)") Pods without resource configuration"
    echo -e "$no_resources" | sed 's/^/  /'
  else
    success "All pods have resource configuration"
  fi
}

###############################################################################
# POD RESTART COUNTS (STABILITY)
###############################################################################
function PodRestarts {
  print_header_second "POD STABILITY (Restarts > 5)"

  local high_restarts
  high_restarts=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    .items[] |
    select(.status.containerStatuses != null) |
    . as $pod |
    $pod.status.containerStatuses[]? |
    select(.restartCount > 5) |
    "\($pod.metadata.namespace)/\($pod.metadata.name) (\(.name): \(.restartCount) restarts)"
  ' 2>/dev/null)

  if [ -n "$high_restarts" ]; then
    warn "$(clean_number "$(echo "$high_restarts" | wc -l)") containers with > 5 restarts:"
    echo -e "$high_restarts" | sed 's/^/  /'
  else
    success "No containers with excessive restarts"
  fi
}

###############################################################################
# PROBLEM PODS (quick visibility, not just the silent score contribution)
# 'Completed' job pods are healthy - old grep counted them as errors.
###############################################################################
function PodIssues {
  print_header_second "PROBLEM PODS (Pending/Failed/Error)"

  local problem_pods
  problem_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null \
    | grep -Ev 'Running|Completed' | head -10)

  if [ -n "$problem_pods" ]; then
    warn "Pods not Running/Completed:"
    echo "$problem_pods" | awk '{printf "  %s/%s [%s]\n", $1, $2, $4}'
  else
    success "All pods Running or Completed"
  fi
}

###############################################################################
# POD SECURITY STANDARDS
###############################################################################
function PODSecurity {
  print_header_second "POD SECURITY"

  local priv_count hostnamespaces run_as_root

  privileged=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
      [.items[] | select(.spec.containers[]?.securityContext?.privileged == true) |
      "\(.metadata.namespace)/\(.metadata.name)"] | .[]' 2>/dev/null || echo "")

  if [ -n "$privileged" ]; then
    priv_count=$(clean_number "$(echo "$privileged" | wc -l)")
    warn "$priv_count Privileged containers found:"
    echo -e "$privileged" | sed 's/^/  /'
  else
    success "No privileged containers"
    privileged=""  # empty string for score check
  fi

  hostnamespaces=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true) |
    "\(.metadata.namespace)/\(.metadata.name) (hostNetwork:\(.spec.hostNetwork // false)/hostPID:\(.spec.hostPID // false)/hostIPC:\(.spec.hostIPC // false))"] | .[]' 2>/dev/null)

  if [ -n "$hostnamespaces" ]; then
    warn "Pods with host namespace access:"
    echo -e "$hostnamespaces" | sed 's/^/  /'
  fi

  # Hint only: unset runAsNonRoot includes virtually every unhardened workload
  run_as_root=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.containers[]?.securityContext?.runAsNonRoot != true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[:5] | .[]' 2>/dev/null)

  if [ -n "$run_as_root" ]; then
    warn "Sample: Pods that may be running as root (runAsNonRoot not set, max 5):"
    echo -e "$run_as_root" | sed 's/^/  /'
  fi
}

###############################################################################
# NETWORK POLICIES
# Batched: namespaces with policies extracted from one -A listing via comm,
# instead of one kubectl call per namespace.
###############################################################################
function NetworkPolicies {
  print_header_second "NETWORK POLICIES"

  np_count=$(clean_number "$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l)")
  info "$np_count NetworkPolicies across $total_ns Namespaces"

  local unprotected_ns
  unprotected_ns=$(comm -23 \
    <(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -Ev '^(default|kube-system)$' | sort) \
    <(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null \
      | awk '{print $1}' | sort -u))

  if [ -n "$unprotected_ns" ]; then
    warn "Namespaces without NetworkPolicy:"
    echo -e "$unprotected_ns" | sed 's/^/  /'
  fi
}

###############################################################################
# RBAC & SERVICE ACCOUNTS
###############################################################################
function ConfigRBAC {
  print_header_second "RBAC CONFIGURATION"

  local cluster_admin_bindings sa_tokens sa_count
  cluster_admin_bindings=$(kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.subjects[*].name}{"\n"}{end}' 2>/dev/null)

  if [ -n "$cluster_admin_bindings" ]; then
    warn "Service accounts with cluster-admin access:"
    echo -e "$cluster_admin_bindings" | sed 's/^/  /'
  fi

  # Only SAs that explicitly opt in (true); null = inherit from pod spec.
  # The 'default' SA of every namespace is excluded (always present, not actionable).
  sa_tokens=$(kubectl get serviceaccounts --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.metadata.name != "default") |
     select(.automountServiceAccountToken == true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[]' 2>/dev/null)

  sa_count=$(clean_number "$(echo "$sa_tokens" | grep -c .)")
  info "ServiceAccounts with explicit automount=true: $sa_count"
  [ -n "$sa_tokens" ] && echo -e "$sa_tokens" | sed 's/^/  /'
}

###############################################################################
# POD DISRUPTION BUDGETS
# Replaced the fragile 'deployments_with_pdb' guess (jsonpath broke silently on
# PDBs without matchLabels.app) with one jq pass over status fields.
###############################################################################
function PODDisruptionBudgets {
  print_header_second "POD DISRUPTION BUDGETS (Availability)"

  pdb_count=$(clean_number "$(kubectl get poddisruptionbudgets --all-namespaces --no-headers 2>/dev/null | wc -l)")

  if [ "$pdb_count" -eq 0 ]; then
    info "No PodDisruptionBudgets configured"
    return
  fi

  local pdb_json blocked_pdbs
  pdb_json=$(kubectl get pdb --all-namespaces -o json 2>/dev/null)

  echo "$pdb_json" | jq -r '.items[] |
    "  \(.metadata.namespace)/\(.metadata.name): allowed=\(.status.disruptionsAllowed // "?") healthy=\(.status.currentHealthy // 0)/\(.status.desiredHealthy // 0)"'

  blocked_pdbs=$(echo "$pdb_json" | jq -r '
    .items[] |
    select((.status.disruptionsAllowed // 0) <= 0 and (.status.desiredHealthy // 0) > 0) |
    "\(.metadata.namespace)/\(.metadata.name)"')

  if [ -n "$blocked_pdbs" ]; then
    warn "PDBs currently blocking any disruption:"
    echo -e "$blocked_pdbs" | sed 's/^/  /'
  fi
}

###############################################################################
# HORIZONTAL POD AUTOSCALERS
###############################################################################
function PODAutoscaling {
  print_header_second "AUTOSCALING (HPA/VPA)"

  hpa_count=$(clean_number "$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)")
  info "HPAs active: $hpa_count"

  if [ "$hpa_count" -gt 0 ]; then
    echo ""
    kubectl get hpa --all-namespaces -o custom-columns=\
    NAMESPACE:.metadata.namespace,\
    NAME:.metadata.name,\
    REFERENCE:.spec.scaleTargetRef.kind/.spec.scaleTargetRef.name,\
    MIN:.spec.minReplicas,\
    MAX:.spec.maxReplicas,\
    CURRENT:.status.currentReplicas \
    --no-headers 2>/dev/null | column -t
  fi
}

###############################################################################
# STORAGE STATUS
###############################################################################
function StorageCheck {
  print_header_second "STORAGE STATUS"

  local sc_count default_sc
  sc_count=$(clean_number "$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l)")
  default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)

  info "StorageClasses: $sc_count"
  [ -n "$default_sc" ] && success "Default SC: $default_sc" || warn "No Default StorageClass"

  local pv_total pv_available pv_bound pv_failed pvc_total pvc_pending
  pv_total=$(clean_number "$(kubectl get pv --no-headers 2>/dev/null | wc -l)")
  pv_available=$(clean_number "$(kubectl get pv --no-headers 2>/dev/null | grep -c Available)")
  pv_bound=$(clean_number "$(kubectl get pv --no-headers 2>/dev/null | grep -c Bound)")
  pv_failed=$(clean_number "$(kubectl get pv --no-headers 2>/dev/null | grep -c Failed)")

  info "PVs: Total=$pv_total | Available=$pv_available | Bound=$pv_bound | Failed=$pv_failed"

  if [ "$pv_failed" -gt 0 ]; then
    warn "Failed PVs:"
    kubectl get pv --no-headers 2>/dev/null | grep Failed | awk '{print "  ├─ "$1}'
  fi

  pvc_total=$(clean_number "$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)")
  pvc_pending=$(clean_number "$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c Pending)")

  info "PVCs: Total=$pvc_total | Pending=$pvc_pending"

  if [ "$pvc_pending" -gt 0 ]; then
    warn "Pending PVCs:"
    kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep Pending | awk '{print "  ├─ "$1"/"$2}'
  fi

  # Node memory usage via metrics-server
  info "Node Memory Usage (via metrics-server):"
  local node mem_usage
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    mem_usage=$(kubectl top node "$node" 2>/dev/null | tail -1 | awk '{print $3}')
    [ -n "$mem_usage" ] && echo -e "  ├─ ${node}: ${mem_usage}" || info "  ├─ ${node}: metrics unavailable"
  done
}

###############################################################################
# BACKUP & DR PREPAREDNESS
# Fixed: VolumeSnapshotContents are CLUSTER-SCOPED - the old per-namespace loop
# was meaningless (and fired one API call per namespace).
###############################################################################
function BackupStatus {
  print_header_second "BACKUP STATUS"

  velero_deployed=$(clean_number "$(kubectl get deployment -n velero velero --no-headers 2>/dev/null | wc -l)")

  if [ "$velero_deployed" -gt 0 ]; then
    success "Velero backup installed"

    if command -v velero &>/dev/null; then
      local backups_scheduled backups_non_scheduled
      backups_scheduled=$(velero schedule get 2>/dev/null | tail -n +2 | grep -c . || echo "0")
      backups_non_scheduled=$(velero backup get 2>/dev/null | tail -n +2 | grep -c . || echo "0")
      info "Scheduled Backups: $(clean_number "$backups_scheduled")"
      info "Manual/Non-Scheduled Backups: $(clean_number "$backups_non_scheduled")"
    else
      warn "Velero CLI not found - skipping backup listing"
    fi
  else
    warn "No Velero backup installed!"
  fi

  # VolumeSnapshotContents: cluster-scoped, one guarded call
  if kubectl api-resources 2>/dev/null | grep -q "volumesnapshotcontents"; then
    local vs_count
    vs_count=$(clean_number "$(kubectl get volumesnapshotcontents --no-headers 2>/dev/null | wc -l)")
    [ "$vs_count" -gt 0 ] && info "VolumeSnapshotContents (cluster-wide): $vs_count"
  fi
}

###############################################################################
# OBSERVABILITY STACK
###############################################################################
function ObservabilityStack {
  print_header_second "OBSERVABILITY STACK"

  local logging_installed=false ns grafana_running alertmanager_running
  for ns in logging elk elasticsearch fluentd loki grafana-loki; do
    if kubectl get deployment -n "$ns" --no-headers 2>/dev/null | grep -q "."; then
      logging_installed=true
      echo -e "${GREEN}Logging:${RESET} $ns Namespace exists"
      break
    fi
  done
  $logging_installed || warn "No central logging stack found"

  for ns in monitoring prometheus; do
    if kubectl get deployment -n "$ns" --no-headers 2>/dev/null | grep -q "prometheus"; then
      echo -e "${GREEN}Monitoring:${RESET} Prometheus in $ns"
    fi
  done

  grafana_running=$(clean_number "$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c grafana)")
  [ "$grafana_running" -gt 0 ] && echo -e "${GREEN}Dashboards:${RESET} Grafana ($grafana_running Pods)"

  alertmanager_running=$(clean_number "$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c alertmanager)")
  [ "$alertmanager_running" -gt 0 ] && echo -e "${GREEN}Alerting:${RESET} AlertManager ($alertmanager_running Pods)"
}

###############################################################################
# GITOPS / CI/CD INTEGRATION
###############################################################################
function GitOps {
  print_header_second "GITOPS / CI/CD INTEGRATION"

  argocd_installed=$(clean_number "$(kubectl get namespace argocd --no-headers 2>/dev/null | wc -l)")

  if [ "$argocd_installed" -gt 0 ]; then
    success "ArgoCD GitOps installed"
    local apps_sync
    apps_sync=$(argocd app list 2>/dev/null | grep -c Synced || echo "0")
    info "Synced Applications: $(clean_number "$apps_sync")"
  else
    info "ArgoCD not found"
  fi

  flux_installed=$(clean_number "$(kubectl get namespace flux-system --no-headers 2>/dev/null | wc -l)")

  if [ "$flux_installed" -gt 0 ]; then
    success "Flux CD installed"

    if kubectl api-resources 2>/dev/null | grep -q "helmrelease"; then
      local hr_count
      hr_count=$(clean_number "$(kubectl get helmrelease --all-namespaces --no-headers 2>/dev/null | wc -l)")
      [ "$hr_count" -gt 0 ] && info "HelmReleases: $hr_count"
    fi

    if kubectl api-resources 2>/dev/null | grep -q "kustomization"; then
      local ku_count
      ku_count=$(clean_number "$(kubectl get kustomization --all-namespaces --no-headers 2>/dev/null | wc -l)")
      [ "$ku_count" -gt 0 ] && info "Kustomizations: $ku_count"
    fi
  else
    info "Flux CD not found"
  fi
}

###############################################################################
# SECRET MANAGEMENT
###############################################################################
function SecretManagement {
  print_header_second "SECRET SECURITY"

  local total_secrets basic_secrets
  total_secrets=$(kubectl get secrets --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  basic_secrets=$(kubectl get secrets --all-namespaces --no-headers 2>/dev/null | grep "Opaque" | wc -l | tr -d '[:space:]')

  info "Total Secrets: ${total_secrets:-0} | Opaque: ${basic_secrets:-0}"

  local external_secret_op sealed_secrets
  external_secret_op=$(clean_number "$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c 'external-secrets')")
  if [ "$external_secret_op" -gt 0 ]; then
    success "External Secrets Controller active"
  else
    warn "No ExternalSecrets operator - manual secret management"
  fi

  sealed_secrets=$(clean_number "$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c 'sealed-secrets')")
  [ "$sealed_secrets" -gt 0 ] && success "Sealed Secrets in use"
}

###############################################################################
# SECURITY POLICIES & ADMISSION
# Batched: PSA label count from one JSON call instead of one call per namespace.
###############################################################################
function Security {
  print_header_second "SECURITY POLICIES & ADMISSION"

  local gatekeeper kyverno
  gatekeeper=$(clean_number "$(kubectl get deployment -n gatekeeper-system --no-headers 2>/dev/null | wc -l)")
  [ "$gatekeeper" -gt 0 ] && success "OPA Gatekeeper active" || info "OPA Gatekeeper not found"

  kyverno=$(clean_number "$(kubectl get deployment -n kyverno --no-headers 2>/dev/null | wc -l)")
  [ "$kyverno" -gt 0 ] && success "Kyverno Policy Engine active" || info "Kyverno not found"

  admission_labeled=$(clean_number "$(kubectl get namespaces -o json 2>/dev/null | jq \
    '[.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] != null)] | length')")

  info "PSA labeled namespaces: $admission_labeled/$total_ns"
}

###############################################################################
# EMERGENCY COMMANDS (opt-in via -e/--emergency)
###############################################################################
function EmergencyCommands {
  print_header "EMERGENCY COMMANDS"
  cat << 'EOF'
Troubleshooting:
  kubectl describe pod <problem-pod> -n <namespace>
  kubectl logs -f <pod-name> -n <namespace> --previous

Emergency Scale:
  kubectl scale deployment/<name> --replicas=0 -n <namespace>

Drain Node:
  kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

Exec into Pod:
  kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
EOF
  echo ""
}

###############################################################################
# PRODUCTION READINESS SCORE
###############################################################################
function Score {
  print_header "PRODUCTION READINESS SCORE"

  local score passed total_checks
  score=0
  total_checks=13
  passed=0

  # Check 1: All Nodes Ready
  local ready_nodes total_nodes
  ready_nodes=$(clean_number "$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready)")
  total_nodes=$(clean_number "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)")
  if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
    ((passed++))
  fi

  # Check 2: No Critical Pod Issues (Completed job pods are OK)
  local critical_pods
  critical_pods=$(clean_number "$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -Ec 'Pending|Failed|Error')")
  [ "$critical_pods" -eq 0 ] && ((passed++))

  # Check 3: No High-Restart Containers
  local high_restarts
  high_restarts=$(clean_number "$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq '[.items[] | .status.containerStatuses[]? | select(.restartCount > 5)] | length')")
  [ "$high_restarts" -eq 0 ] && ((passed++))

  # Check 4: PDBs configured
  [ "$pdb_count" -ge 2 ] && ((passed++))

  # Check 5: HPAs configured
  [ "$hpa_count" -ge 2 ] && ((passed++))

  # Check 6: NetworkPolicies with meaningful coverage
  [ "$np_count" -ge 5 ] && ((passed++))

  # Check 7: Velero backup installed
  [ "$velero_deployed" -gt 0 ] && ((passed++))

  # Check 8: No privileged containers
  [ -z "$privileged" ] && ((passed++))

  # Check 9: PSA enforcement enabled on majority of namespaces
  [ "$admission_labeled" -ge 8 ] && ((passed++))

  # Check 10: Resource quotas configured
  [ "$quota_total" -gt 0 ] && ((passed++))

  # Check 11: GitOps (ArgoCD or Flux)
  if [ "$argocd_installed" -gt 0 ] || [ "$flux_installed" -gt 0 ]; then
    ((passed++))
  fi

  # Check 12: Monitoring stack present
  local prom_ns
  prom_ns=$(clean_number "$(kubectl get namespace monitoring 2>/dev/null | grep -c monitoring)")
  [ "$prom_ns" -gt 0 ] && ((passed++))

  # Check 13: Control plane healthy (no non-running pods in kube-system)
  local cp_issues
  cp_issues=$(clean_number "$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -Ev 'Running|Completed' | wc -l)")
  [ "$cp_issues" -eq 0 ] && ((passed++))

  score=$((passed * 100 / total_checks))

  # FIXED: score is a plain integer - old patterns like '90-100' matched the
  # literal string and colored almost every result RED
  local score_color
  case $score in
    9[0-9]|100) score_color="$GREEN" ;;
    [78][0-9])  score_color="$YELLOW" ;;
    *)          score_color="$RED" ;;
  esac

  echo -e "${BOLD}Score: ${score_color}${score}%${RESET} ($passed/$total_checks checks passed)"
  echo ""

  echo -e "${DIM}Breakdown:${RESET}"
  echo -e "${DIM}  Nodes Ready:${RESET} $ready_nodes/$total_nodes"
  echo -e "${DIM}  Critical Pods:${RESET} $critical_pods"
  echo -e "${DIM}  High Restarts (>5):${RESET} $high_restarts"
  echo -e "${DIM}  PDBs (>=2):${RESET} $pdb_count"
  echo -e "${DIM}  HPAs (>=2):${RESET} $hpa_count"
  echo -e "${DIM}  NetworkPolicies (>=5):${RESET} $np_count"
  echo -e "${DIM}  PSA Labeled:${RESET} $admission_labeled/$total_ns"
  echo -e "${DIM}  Resource Quotas:${RESET} $quota_total"

  echo ""
  echo -e "${DIM}Cluster Production Check completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

###############################################################################
# MAIN EXECUTION
###############################################################################
ClusterInfo
HelmInfo
ControlPlaneHealth
CertificateExpiration
StorageCheck
BackupStatus
ResourceQuotasLimits
PodRestarts
PodIssues
PODSecurity
NetworkPolicies
ConfigRBAC
PODDisruptionBudgets
PODAutoscaling
ObservabilityStack
GitOps
SecretManagement
Security

# Opt-in cheat sheet
if [ "$SHOW_EMERGENCY" -eq 1 ]; then
  EmergencyCommands
fi

Score
