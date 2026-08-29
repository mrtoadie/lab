#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# KUBERNETES PRODUCTION READINESS CHECK SCRIPT
# Author: toadie
# Description: Comprehensive cluster health and production readiness assessment
###############################################################################

# Global counters and flags
declare -i pdb_count=0
declare -i hpa_count=0
declare -i np_count=0
declare -i velero_deployed=0
declare -i admission_labeled=0
declare -i argocd_installed=0
declare -i flux_installed=0
declare privileged=""
declare total_ns=0
declare quota_total=0

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

###############################################################################
# CLUSTER BASICS
###############################################################################
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

###############################################################################
# HELM VERSION CHECK
###############################################################################
function HelmInfo {
  if command -v helm &>/dev/null; then
    local helm_ver
    helm_ver=$(helm version --short 2>/dev/null || echo "unknown")
    success "Helm Client: $helm_ver"
    
    local repo_count
    repo_count=$(helm repo list 2>/dev/null | tail -n +2 | wc -l || echo "0")
    info "Helm Repositories: $repo_count"
  else
    info "Helm CLI not in PATH"
  fi
}

###############################################################################
# CONTROL PLANE COMPONENTS HEALTH
###############################################################################
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

###############################################################################
# CERTIFICATE EXPIRATION CHECK
###############################################################################
function CertificateExpiration {
  print_header_second "CERTIFICATES & TLS"

  # 1. k3s API Server Certificate from filesystem
  local k3s_cert_path="/etc/rancher/k3s/server/tls/server.crt"
  local expiry_date api_cert end_date expiry_epoch current_epoch days_until
  local warning_certs="" expired_certs=""
  local ns name cert_data

  if [ -f "$k3s_cert_path" ] && [ -r "$k3s_cert_path" ]; then
    expiry_date=$(openssl x509 -in "$k3s_cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry_date" ]; then
      echo -e "${CYAN}API Server (k3s):${RESET} Expires $expiry_date"
    fi
  else
    # Fallback for kubeadm or cert-manager managed certs
    api_cert=$(kubectl get secret -n kube-system kube-api-serving-cert -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "")
    if [ -n "$api_cert" ]; then
      expiry_date=$(echo "$api_cert" | cut -d= -f2)
      echo -e "${CYAN}API Server:${RESET} Expires $expiry_date"
    else
      info "API Server Certificate cannot be verified (kubeadm/cert-manager or no root access)"
    fi
  fi

  # 2. Count TLS secrets
  local tls_certs
  tls_certs=$(kubectl get secrets --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.type}{"\n"}{end}' 2>/dev/null | grep tls | wc -l)
  tls_certs=$(clean_number "$tls_certs")
  info "TLS Secrets found: $tls_certs"

  # 3. Check certificate expiration using while-read (safer than for loop)
  while IFS='|' read -r ns name cert_data; do
    if [ -n "$cert_data" ] && [ "$cert_data" != "null" ]; then
      end_date=$(echo "$cert_data" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      
      if [ -n "$end_date" ]; then
        expiry_epoch=$(date -d "$end_date" +%s 2>/dev/null)
        current_epoch=$(date +%s)
        
        if [ -n "$expiry_epoch" ]; then
          days_until=$(( (expiry_epoch - current_epoch) / 86400 ))
          
          if [ "$days_until" -lt 30 ] && [ "$days_until" -gt 0 ]; then
            warning_certs="${warning_certs}${ns}/${name} ($days_until days)\n"
          elif [ "$days_until" -le 0 ]; then
            expired_certs="${expired_certs}${ns}/${name} EXPIRED!\n"
          fi
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
###############################################################################
function ResourceQuotasLimits {
  print_header_second "RESOURCE QUOTAS & LIMIT RANGES"
  
  local ns quota_count limit_range_count q used hard
  quota_total=0  # Initialize counter

  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    quota_count=$(kubectl get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l)
    quota_count=$(clean_number "$quota_count")
    limit_range_count=$(kubectl get limitrange -n "$ns" --no-headers 2>/dev/null | wc -l)
    limit_range_count=$(clean_number "$limit_range_count")
    quota_total=$((quota_total + quota_count))

    if [ "$quota_count" -gt 0 ] || [ "$limit_range_count" -gt 0 ]; then
      info "$ns: ${quota_count} ResourceQuotas, ${limit_range_count} LimitRanges"

      kubectl get resourcequota -n "$ns" --no-headers 2>/dev/null | while read -r line; do
        q=$(echo "$line" | awk '{print $1}')
        used=$(echo "$line" | awk '{print $5}')
        hard=$(echo "$line" | awk '{print $3}')
        echo -e "  ├─ ${q}: Used ${used}/${hard}"
      done
    fi
  done

  # Check pods without resource requests/limits
  info "Pods without resource requests or limits:"
  local no_resources
  no_resources=$(kubectl get pods --all-namespaces -o custom-columns=\
  NS:.metadata.namespace,\
  POD:.metadata.name,\
  HAS_REQUESTS:.spec.containers[*].resources.requests,\
  HAS_LIMITS:.spec.containers[*].resources.limits \
  --no-headers 2>/dev/null | awk '$3=="" || $4==""' | head -10)

  if [ -n "$no_resources" ]; then
    local count
    count=$(echo "$no_resources" | wc -l)
    count=$(clean_number "$count")
    warn "$count Pods without resource configuration"
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
    local count
    count=$(echo "$high_restarts" | wc -l)
    count=$(clean_number "$count")
    warn "$count containers with > 5 restarts:"
    echo -e "$high_restarts" | sed 's/^/  /'
  else
    success "No containers with excessive restarts"
  fi
}

###############################################################################
# POD SECURITY STANDARDS
###############################################################################
function PODSecurity {
  print_header_second "POD SECURITY"

  # Check privileged containers
  local priv_count
  privileged=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
      [.items[] | select(.spec.containers[]?.securityContext?.privileged == true) |
      "\(.metadata.namespace)/\(.metadata.name)"] | .[]' 2>/dev/null || echo "")

  if [ -n "$privileged" ]; then
    priv_count=$(echo "$privileged" | wc -l)
    priv_count=$(clean_number "$priv_count")
    warn "$priv_count Privileged containers found:"
    echo -e "$privileged" | sed 's/^/  /'
  else
    success "No privileged containers"
    privileged=""  # Empty string for score check
  fi

  # Check host namespace access
  local hostnamespaces
  hostnamespaces=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true) |
    "\(.metadata.namespace)/\(.metadata.name) (hostNetwork:\(.spec.hostNetwork)//hostPID:\(.spec.hostPID)//hostIPC:\(.spec.hostIPC))"] | .[]' 2>/dev/null)

  if [ -n "$hostnamespaces" ]; then
    warn "Pods with host namespace access:"
    echo -e "$hostnamespaces" | sed 's/^/  /'
  fi

  # Check runAsNonRoot setting
  local run_as_root
  run_as_root=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.containers[]?.securityContext?.runAsNonRoot != true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[:5] | .[]' 2>/dev/null)

  if [ -n "$run_as_root" ]; then
    warn "Pods that may be running as root (runAsNonRoot not set):"
    echo -e "$run_as_root" | sed 's/^/  /'
  fi
}

###############################################################################
# NETWORK POLICIES
###############################################################################
function NetworkPolicies {
  print_header_second "NETWORK POLICIES"

  np_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l)
  np_count=$(clean_number "$np_count")

  info "$np_count NetworkPolicies across $total_ns Namespaces"

  # Find unprotected namespaces
  local np unprotected_ns=""
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    np=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
    np=$(clean_number "$np")
    if [ "$np" -eq 0 ] && [ "$ns" != "default" ] && [ "$ns" != "kube-system" ]; then
      unprotected_ns="${unprotected_ns}${ns}\n"
    fi
  done

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

  local cluster_admin_bindings sa_tokens
  cluster_admin_bindings=$(kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.subjects[*].name}{"\n"}{end}' 2>/dev/null)
  
  if [ -n "$cluster_admin_bindings" ]; then
    warn "Service accounts with cluster-admin access:"
    echo -e "$cluster_admin_bindings" | sed 's/^/  /'
  fi

  sa_tokens=$(kubectl get serviceaccounts --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.automountServiceAccountToken == null or .automountServiceAccountToken == true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[]' 2>/dev/null)

  local sa_count
  sa_count=$(echo "$sa_tokens" | wc -l)
  sa_count=$(clean_number "$sa_count")
  info "ServiceAccounts (automount=true): $sa_count"
}

###############################################################################
# POD DISRUPTION BUDGETS
###############################################################################
function PODDisruptionBudgets {
  print_header_second "POD DISRUPTION BUDGETS (Availability)"

  pdb_count=$(kubectl get poddisruptionbudgets --all-namespaces --no-headers 2>/dev/null | wc -l)
  pdb_count=$(clean_number "$pdb_count")
  
  local deployments_with_pdb
  deployments_with_pdb=$(kubectl get pdb --all-namespaces -o jsonpath='{.items[*].spec.selector.matchLabels.app}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l)
  deployments_with_pdb=$(clean_number "$deployments_with_pdb")

  info "PDBs configured: $pdb_count (Coverage: ~$deployments_with_pdb Deployments)"

  # Check for blocking PDBs
  local blocking_pdbs="" pdb status
  for pdb in $(kubectl get pdb --all-namespaces -o name 2>/dev/null); do
    status=$(kubectl get "$pdb" -o jsonpath='{.status.statuses[*].conditions[-1:].reason}' 2>/dev/null)
    if [[ "$status" == *"Disrupting"* ]]; then
      blocking_pdbs="${blocking_pdbs}${pdb}\n"
    fi
  done

  if [ -n "$blocking_pdbs" ]; then
    warn "Currently blocking PDBs:"
    echo -e "$blocking_pdbs" | sed 's/^/  /'
  fi
}

###############################################################################
# HORIZONTAL POD AUTOSCALERS
###############################################################################
function PODAutoscaling {
  print_header_second "AUTOSCALING (HPA/VPA)"

  hpa_count=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)
  hpa_count=$(clean_number "$hpa_count")
  info "HPAs active: $hpa_count"

  if [ "$hpa_count" -gt 0 ]; then
    echo ""
    kubectl get hpa --all-namespaces -o custom-columns=\
    NAMESPACE:.metadata.namespace,\
    NAME:.metadata.name,\
    REFERENCE:.spec.scaleTargetRef.kind/.spec.scaleTargetRef.name,\
    MIN:.spec.minReplicas,\
    MAX:.spec.maxReplicas,\
    CURRENT:.status.currentReplicas,\
    TARGET:.spec.targetCPUUtilizationPercentage \
    --no-headers 2>/dev/null | column -t
  fi
}

###############################################################################
# STORAGE STATUS
###############################################################################
function StorageCheck {
  print_header_second "STORAGE STATUS"

  # StorageClasses
  local sc_count default_sc
  sc_count=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l)
  sc_count=$(clean_number "$sc_count")
  default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
  
  info "StorageClasses: $sc_count"
  [ -n "$default_sc" ] && success "Default SC: $default_sc" || warn "No Default StorageClass"

  # PersistentVolumes
  local pv_total pv_available pv_bound pv_failed
  pv_total=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  pv_available=$(kubectl get pv --no-headers 2>/dev/null | grep -c Available || echo "0")
  pv_bound=$(kubectl get pv --no-headers 2>/dev/null | grep -c Bound || echo "0")
  pv_failed=$(kubectl get pv --no-headers 2>/dev/null | grep -c Failed || echo "0")

  pv_total=$(clean_number "$pv_total")
  pv_available=$(clean_number "$pv_available")
  pv_bound=$(clean_number "$pv_bound")
  pv_failed=$(clean_number "$pv_failed")

  info "PVs: Total=$pv_total | Available=$pv_available | Bound=$pv_bound | Failed=$pv_failed"

  if [ "$pv_failed" -gt 0 ]; then
    warn "Failed PVs:"
    kubectl get pv --no-headers 2>/dev/null | grep Failed | awk '{print "  ├─ "$1}'
  fi

  # PersistentVolumeClaims
  local pvc_total pvc_pending
  pvc_total=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
  pvc_pending=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c Pending || echo "0")

  pvc_total=$(clean_number "$pvc_total")
  pvc_pending=$(clean_number "$pvc_pending")

  info "PVCs: Total=$pvc_total | Pending=$pvc_pending"

  if [ "$pvc_pending" -gt 0 ]; then
    warn "Pending PVCs:"
    kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep Pending | awk '{print "  ├─ "$1"/"$2}'
  fi

  # Node Resource Usage (memory from metrics-server)
  info "Node Memory Usage (via metrics-server):"
  local node disk_usage
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    disk_usage=$(kubectl top node "$node" 2>/dev/null | tail -1 | awk '{print $2}')
    [ -n "$disk_usage" ] && echo -e "  ├─ ${node}: ${disk_usage}" || info "  ├─ ${node}: metrics unavailable"
  done
}

###############################################################################
# BACKUP & DR PREPAREDNESS
###############################################################################
function BackupStatus {
  print_header_second "BACKUP STATUS"

  velero_deployed=$(kubectl get deployment -n velero velero --no-headers 2>/dev/null | wc -l)
  velero_deployed=$(clean_number "$velero_deployed")

  if [ "$velero_deployed" -gt 0 ]; then
    success "Velero Backup installed"
    
    # Exclude header line with tail -n +2
    local backups_scheduled backups_non_scheduled
    backups_scheduled=$(velero schedule get 2>/dev/null | tail -n +2 | grep -c . || echo "0")
    backups_non_scheduled=$(velero backup get 2>/dev/null | tail -n +2 | grep -c . || echo "0")
    
    info "Scheduled Backups: $backups_scheduled"
    info "Manual/Non-Scheduled Backups: $backups_non_scheduled"
  else
    warn "No Velero backup installed!"
  fi

  # Check volume snapshots per namespace
  local ns volumesnapshots
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    volumesnapshots=$(kubectl get volumesnapshotcontents -n "$ns" --no-headers 2>/dev/null | wc -l)
    volumesnapshots=$(clean_number "$volumesnapshots")
    if [ "$volumesnapshots" -gt 0 ]; then
      info "$ns: $volumesnapshots Volume Snapshots available"
    fi
  done
}

###############################################################################
# OBSERVABILITY STACK
###############################################################################
function ObservabilityStack {
  print_header_second "OBSERVABILITY STACK"

  local logging_installed=false
  for ns in logging elk elasticsearch fluentd loki grafana-loki; do
    if kubectl get deployment -n "$ns" --no-headers 2>/dev/null | grep -q "."; then
      logging_installed=true
      echo -e "${GREEN}Logging:${RESET} $ns Namespace exists"
      break
    fi
  done
  $logging_installed || warn "No central logging stack found"

  # Check Prometheus
  for ns in monitoring prometheus; do
    if kubectl get deployment -n "$ns" --no-headers 2>/dev/null | grep -q "prometheus"; then
      echo -e "${GREEN}Monitoring:${RESET} Prometheus in $ns"
    fi
  done

  local grafana_running alertmanager_running
  grafana_running=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "grafana" || echo "0")
  grafana_running=$(clean_number "$grafana_running")
  if [ "$grafana_running" -gt 0 ]; then
    echo -e "${GREEN}Dashboards:${RESET} Grafana ($grafana_running Pods)"
  fi

  alertmanager_running=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "alertmanager" || echo "0")
  alertmanager_running=$(clean_number "$alertmanager_running")
  if [ "$alertmanager_running" -gt 0 ]; then
    echo -e "${GREEN}Alerting:${RESET} AlertManager ($alertmanager_running Pods)"
  fi
}

###############################################################################
# GITOPS / CI/CD INTEGRATION
###############################################################################
function GitOps {
  print_header_second "GITOPS / CI/CD INTEGRATION"

  argocd_installed=$(kubectl get namespace argocd --no-headers 2>/dev/null | wc -l)
  argocd_installed=$(clean_number "$argocd_installed")
  
  if [ "$argocd_installed" -gt 0 ]; then
    success "ArgoCD GitOps installed"
    local apps_sync
    apps_sync=$(argocd app list 2>/dev/null | grep Synced | wc -l || echo "0")
    apps_sync=$(clean_number "$apps_sync")
    info "Synced Applications: $apps_sync"
  else
    info "ArgoCD not found"
  fi

  flux_installed=$(kubectl get namespace flux-system --no-headers 2>/dev/null | wc -l)
  flux_installed=$(clean_number "$flux_installed")
  
  if [ "$flux_installed" -gt 0 ]; then
    success "Flux CD installed"
    
    if kubectl api-resources 2>/dev/null | grep -q "helmrelease"; then
      local hr_count
      hr_count=$(kubectl get helmrelease --all-namespaces --no-headers 2>/dev/null | wc -l)
      hr_count=$(clean_number "$hr_count")
      [ "$hr_count" -gt 0 ] && info "HelmReleases: $hr_count"
    fi
    
    if kubectl api-resources 2>/dev/null | grep -q "kustomization"; then
      local ku_count
      ku_count=$(kubectl get kustomization --all-namespaces --no-headers 2>/dev/null | wc -l)
      ku_count=$(clean_number "$ku_count")
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

  # External Secrets Operator check
  local external_secret_output external_secret_op
  external_secret_output=$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c "external-secrets" 2>/dev/null || echo "0")
  external_secret_op=$(echo "$external_secret_output" | tr -d '[:space:]')
  [ -z "$external_secret_op" ] && external_secret_op=0

  if [ "$external_secret_op" -gt 0 ]; then
    success "External Secrets Controller active"
  else
    warn "No ExternalSecrets operator - manual secret management"
  fi

  # Sealed Secrets check
  local sealed_secret_output sealed_secrets
  sealed_secret_output=$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c "sealed-secrets" 2>/dev/null || echo "0")
  sealed_secrets=$(echo "$sealed_secret_output" | tr -d '[:space:]')
  [ -z "$sealed_secrets" ] && sealed_secrets=0

  if [ "$sealed_secrets" -gt 0 ]; then
    success "Sealed Secrets in use"
  fi
}

###############################################################################
# SECURITY POLICIES & ADMISSION
###############################################################################
function Security {
  print_header_second "SECURITY POLICIES & ADMISSION"

  local gatekeeper kyverno
  gatekeeper=$(kubectl get deployment -n gatekeeper-system --no-headers 2>/dev/null | wc -l)
  gatekeeper=$(clean_number "$gatekeeper")
  [ "$gatekeeper" -gt 0 ] && success "OPA Gatekeeper active" || info "OPA Gatekeeper not found"

  kyverno=$(kubectl get deployment -n kyverno --no-headers 2>/dev/null | wc -l)
  kyverno=$(clean_number "$kyverno")
  [ "$kyverno" -gt 0 ] && success "Kyverno Policy Engine active" || info "Kyverno not found"

  # Count PSA-labeled namespaces
  local psa
  admission_labeled=0
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    psa=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    [ -n "$psa" ] && admission_labeled=$((admission_labeled + 1))
  done
  
  info "PSA labeled namespaces: $admission_labeled/$total_ns"
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
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo "0")
  ready_nodes=$(clean_number "$ready_nodes")
  total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  total_nodes=$(clean_number "$total_nodes")
  if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
    ((passed++))
  fi

  # Check 2: No Critical Pod Issues
  local critical_pods
  critical_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -E 'Pending|Failed|Error' | wc -l || echo "0")
  critical_pods=$(clean_number "$critical_pods")
  if [ "$critical_pods" -eq 0 ]; then
    ((passed++))
  fi

  # Check 3: No High Restart Containers
  local high_restarts
  high_restarts=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq '[.items[] | .status.containerStatuses[]? | select(.restartCount > 5)] | length' 2>/dev/null || echo "0")
  high_restarts=$(clean_number "$high_restarts")
  [ "$high_restarts" -eq 0 ] && ((passed++))

  # Check 4: PDBs configured (need at least 2 for redundancy)
  [ "$pdb_count" -ge 2 ] && ((passed++))

  # Check 5: HPA configured (need at least 2 for autoscaling)
  [ "$hpa_count" -ge 2 ] && ((passed++))

  # Check 6: NetworkPolicies (need at least 5 for meaningful coverage)
  [ "$np_count" -ge 5 ] && ((passed++))

  # Check 7: Velero backup installed
  [ "$velero_deployed" -gt 0 ] && ((passed++))

  # Check 8: No privileged containers
  [ -z "$privileged" ] && ((passed++))

  # Check 9: PSA enforcement enabled
  [ "$admission_labeled" -ge 8 ] && ((passed++))  # Need majority of namespaces

  # Check 10: Resource quotas configured
  [ "$quota_total" -gt 0 ] && ((passed++))

  # Check 11: GitOps (ArgoCD or Flux)
  [ "$argocd_installed" -gt 0 ] || [ "$flux_installed" -gt 0 ] && ((passed++))

  # Check 12: Monitoring stack present
  local prom_ns
  prom_ns=$(kubectl get namespace monitoring 2>/dev/null | grep -c "monitoring" || echo "0")
  prom_ns=$(clean_number "$prom_ns")
  [ "$prom_ns" -gt 0 ] && ((passed++))

  # Check 13: Control plane healthy
  local cp_issues
  cp_issues=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -cv Running || echo "0")
  cp_issues=$(clean_number "$cp_issues")
  [ "$cp_issues" -eq 0 ] && ((passed++))

  # Calculate score percentage
  score=$((passed * 100 / total_checks))

  # Color based on score range
  local score_color
  case $score in
    90-100) score_color="$GREEN" ;;
    70-89)  score_color="$YELLOW" ;;
    *)      score_color="$RED" ;;
  esac

  echo -e "${BOLD}Score: ${score_color}${score}%${RESET} ($passed/$total_checks checks passed)"
  echo ""
  
  # Detailed breakdown
  echo -e "${DIM}Breakdown:${RESET}"
  echo -e "${DIM}  Nodes Ready:${RESET} $( [ "$ready_nodes" -eq "$total_nodes" ] && echo "Yes" || echo "No" )"
  echo -e "${DIM}  No Critical Pods:${RESET} $( [ "$critical_pods" -eq 0 ] && echo "Yes" || echo "No" )"
  echo -e "${DIM}  Low Restarts:${RESET} $( [ "$high_restarts" -eq 0 ] && echo "Yes" || echo "No" )"
  echo -e "${DIM}  PDBs (≥2):${RESET} $pdb_count"
  echo -e "${DIM}  HPAs (≥2):${RESET} $hpa_count"
  echo -e "${DIM}  NetworkPolicies (≥5):${RESET} $np_count"
  echo -e "${DIM}  PSA Labeled:${RESET} $admission_labeled/$total_ns"
  echo -e "${DIM}  Resource Quotas:${RESET} $quota_total"
  
  echo ""
  echo -e "${DIM}Cluster Production Check completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

###############################################################################
# MAIN EXECUTION
###############################################################################

# Run all checks in order
ClusterInfo
HelmInfo
ControlPlaneHealth
CertificateExpiration
StorageCheck
BackupStatus
ResourceQuotasLimits
PodRestarts
PODSecurity
NetworkPolicies
ConfigRBAC
PODDisruptionBudgets
PODAutoscaling
ObservabilityStack
GitOps
SecretManagement
Security
Score
