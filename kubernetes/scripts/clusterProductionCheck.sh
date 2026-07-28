#!/usr/bin/env bash
set -uo pipefail

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

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

print_header() {
  #echo -e "\n${BOLD}${CYAN}═══════════════════════════ $1 ${CYAN}═══════════════════════════${RESET}"
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

# ============================================
# HELPER FUNCTION - Zahlensäuberung
# ============================================
clean_number() {
  local result="${1:-0}"
  result=$(echo "$result" | tr -d '[:space:]')
  [ -z "$result" ] && result=0
  echo "$result"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CLUSTER BASICS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function ClusterInfo {
  print_header_second "CLUSTER INFOS"
  echo -e "${DIM}Context:${RESET} $(kubectl config current-context 2>/dev/null)"
  echo -e "${DIM}K8s Version:${RESET} $(kubectl version 2>/dev/null | grep Server | awk '{print $3}' || echo "unknown")"
  echo -e "${DIM}Namespaces:${RESET} $(kubectl get namespaces --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Nodes:${RESET} $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Pods Total:${RESET} $(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)"
  echo -e "${DIM}Deployments:${RESET} $(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)"
  #echo ""
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# HELM VERSION CHECK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function HelmInfo {
  if command -v helm &>/dev/null; then
    helm_ver=$(helm version --short 2>/dev/null || echo "unknown")
    success "Helm Client: $helm_ver"
    
    repo_count=$(helm repo list 2>/dev/null | tail -n +2 | wc -l || echo "0")
    info "Helm Repositories: $repo_count"
  else
    info "Helm CLI not in PATH"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONTROL PLANE HEALTH
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function ControlPlaneHealth {
  print_header_second "CONTROL PLANE COMPONENTS"

  components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")
  for component in "${components[@]}"; do
    status=$(kubectl get pods -n kube-system --field-selector metadata.name~"$component" --no-headers 2>/dev/null | grep -v Running | wc -l)
    if [ "$status" -eq 0 ]; then
      success "$component: Healthy"
    else
      error "$component: UNHEALTHY"
    fi
  done

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CERTIFICATE EXPIRATION (Critical!)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CERTIFICATE EXPIRATION (Critical!)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function CertificateExpiration {
  print_header_second "CERTIFICATES & TLS"

  # 1. k3s API Server Certificate direkt vom Dateisystem lesen
  local k3s_cert_path="/etc/rancher/k3s/server/tls/server.crt"
  if [ -f "$k3s_cert_path" ] && [ -r "$k3s_cert_path" ]; then
    expiry_date=$(openssl x509 -in "$k3s_cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry_date" ]; then
      echo -e "${CYAN}API Server (k3s):${RESET} Expires $expiry_date"
    fi
  else
    # Fallback für Standard k8s (kubeadm)
    api_cert=$(kubectl get secret -n kube-system kube-api-serving-cert -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "")
    if [ -n "$api_cert" ]; then
      expiry_date=$(echo "$api_cert" | cut -d= -f2)
      echo -e "${CYAN}API Server:${RESET} Expires $expiry_date"
    else
      info "API Server Certificate cannot be verified (kubeadm/cert-manager or no root access)"
    fi
  fi

  # 2. Ingress TLS Certificates zählen
  tls_certs=$(kubectl get secrets --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.type}{"\n"}{end}' 2>/dev/null | grep tls | wc -l)
  info "TLS Secrets found: $tls_certs"

  # 3. Secrets prüfen (Ablauf < 30 Tage oder EXPIRED)
  warning_certs=""
  expired_certs=""
  
  # Safely extract namespace, name, and cert data using jq
  for secret_info in $(kubectl get secrets --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.type=="kubernetes.io/tls") | "\(.metadata.namespace)|\(.metadata.name)|\(.data["tls.crt"] // "")"' 2>/dev/null); do
    ns=$(echo "$secret_info" | cut -d'|' -f1)
    name=$(echo "$secret_info" | cut -d'|' -f2)
    cert_data=$(echo "$secret_info" | cut -d'|' -f3-)
    
    if [ -n "$cert_data" ] && [ "$cert_data" != "null" ]; then
      end_date=$(echo "$cert_data" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      
      if [ -n "$end_date" ]; then
        # FIXED: Korrekte Datumsumwandlung in Epoch-Sekunden
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
  done

  if [ -n "$expired_certs" ]; then
    error "EXPIRED certificates found:"
    echo -e "$expired_certs" | sed 's/^/  /'
  fi

  if [ -n "$warning_certs" ]; then
    warn "Certificates expiring soon (< 30 days):"
    echo -e "$warning_certs" | sed 's/^/  /'
  fi
}
function CertificateExpirationOld {
  print_header_second "CERTIFICATES & TLS"

  # API Server Certificate
  api_cert=$(kubectl get secret -n kube-system kube-api-serving-cert -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "")
  if [ -n "$api_cert" ]; then
    expiry_date=$(echo "$api_cert" | cut -d= -f2)
    echo -e "${CYAN}API Server:${RESET} Expires $expiry_date"
  else
    info "API Server Certificate cannot be verified (kubeadm/cert-manager)"
  fi

  # Ingress TLS Certificates
  tls_certs=$(kubectl get secrets --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.type}{"\n"}{end}' 2>/dev/null | grep tls | wc -l)
  info "TLS Secrets found: $tls_certs"

  # Check for early expiry (< 30 days)
  warning_certs=""
  expired_certs=""
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    for secret in $(kubectl get secrets -n "$ns" -o name 2>/dev/null); do
      cert_data=$(kubectl get "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
      if [ -n "$cert_data" ]; then
        end_date=$(echo "$cert_data" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        if [ -n "$end_date" ]; then
          days_until=$(( ($(date -d "$end_date +%Y-%m-%d +%s") - $(date +%s)) / 86400 ))
          if [ "$days_until" -lt 30 ] && [ "$days_until" -gt 0 ]; then
            warning_certs="${warning_certs}${ns}/${secret##*/} ($days_until days)\n"
          elif [ "$days_until" -le 0 ]; then
            expired_certs="${expired_certs}${ns}/${secret##*/} EXPIRED!\n"
          fi
        fi
      fi
    done
  done

  if [ -n "$expired_certs" ]; then
    error "EXPIRED certificates found:"
    echo -e "$expired_certs" | sed 's/^/  /'
  fi

  if [ -n "$warning_certs" ]; then
    warn "Certificates expiring soon (< 30 days):"
    echo -e "$warning_certs" | sed 's/^/  /'
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESOURCE QUOTAS & LIMITS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function ResourceQuotasLimits {
  print_header_second "RESOURCE QUOTAS & LIMIT RANGES"

  total_namespaces=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    quota_count=$(kubectl get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l)
    limit_range_count=$(kubectl get limitrange -n "$ns" --no-headers 2>/dev/null | wc -l)

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

  # Pods without Resource Requests/Limits
  echo ""
  info "Pods without resource requests or limits:"
  no_resources=$(kubectl get pods --all-namespaces -o custom-columns=\
  NS:.metadata.namespace,\
  POD:.metadata.name,\
  HAS_REQUESTS:.spec.containers[*].resources.requests,\
  HAS_LIMITS:.spec.containers[*].resources.limits \
  --no-headers 2>/dev/null | awk '$3=="" || $4==""' | head -10)

  if [ -n "$no_resources" ]; then
    warn "$(echo "$no_resources" | wc -l) Pods without resource configuration"
    echo -e "$no_resources" | sed 's/^/  /'
  else
    success "All pods have resource configuration"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# POD SECURITY STANDARDS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function PODSecurity {
  print_header_second "POD SECURITY"

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
      privileged=""  # Leerer String für Score
    fi

  hostnamespaces=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true) |
    "\(.metadata.namespace)/\(.metadata.name) (hostNetwork:\(.spec.hostNetwork)//hostPID:\(.spec.hostPID)//hostIPC:\(.spec.hostIPC))"] | .[]' 2>/dev/null)

  if [ -n "$hostnamespaces" ]; then
    warn "Pods with host namespace access:"
    echo -e "$hostnamespaces" | sed 's/^/  /'
  fi

  run_as_root=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.spec.containers[]?.securityContext?.runAsNonRoot != true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[:5] | .[]' 2>/dev/null)

  if [ -n "$run_as_root" ]; then
    warn "Pods that may be running as root (runAsNonRoot not set):"
    echo -e "$run_as_root" | sed 's/^/  /'
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NETWORK POLICIES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function NetworkPolicies {
  print_header_second "NETWORK POLICIES"

  np_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l)
  np_count=$(clean_number "$np_count")
  
  total_ns=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
  total_ns=$(clean_number "$total_ns")

  info "$np_count NetworkPolicies across $total_ns Namespaces"

  unprotected_ns=$(for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    np=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$np" -eq 0 ] && [ "$ns" != "default" ] && [ "$ns" != "kube-system" ]; then
      echo "$ns"
    fi
  done)

  if [ -n "$unprotected_ns" ]; then
    warn "Namespaces without NetworkPolicy:"
    echo -e "$unprotected_ns" | sed 's/^/  /'
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RBAC & SERVICE ACCOUNTS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function ConfigRBAC {
  print_header_second "RBAC CONFIGURATION"

  cluster_admin_bindings=$(kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.subjects[*].name}{"\n"}{end}' 2>/dev/null)
  if [ -n "$cluster_admin_bindings" ]; then
    warn "Service accounts with cluster-admin access:"
    echo -e "$cluster_admin_bindings" | sed 's/^/  /'
  fi

  sa_tokens=$(kubectl get serviceaccounts --all-namespaces -o json 2>/dev/null | jq -r '
    [.items[] | select(.automountServiceAccountToken == null or .automountServiceAccountToken == true) |
    "\(.metadata.namespace)/\(.metadata.name)"] | .[]' 2>/dev/null)

  info "ServiceAccounts (automount=true): $(echo "$sa_tokens" | wc -l)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# POD DISRUPTION BUDGETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function PODDisruptionBudgets {
  print_header_second "POD DISRUPTION BUDGETS (Availability)"

  pdb_count=$(kubectl get poddisruptionbudgets --all-namespaces --no-headers 2>/dev/null | wc -l)
  pdb_count=$(clean_number "$pdb_count")
  deployments_with_pdb=$(kubectl get pdb --all-namespaces -o jsonpath='{.items[*].spec.selector.matchLabels.app}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l)
  deployments_with_pdb=$(clean_number "$deployments_with_pdb")

  info "PDBs configured: $pdb_count (Coverage: ~$deployments_with_pdb Deployments)"

  blocking_pdbs=""
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# HORIZONTAL POD AUTOSCALERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function PODAutoscaling {
  print_header_second "AUTOSCALING (HPA/VPA)"

  hpa_count=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# BACKUP & DR PREPAREDNESS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function BackupStatus {
  print_header_second "BACKUP STATUS"

  velero_deployed=$(kubectl get deployment -n velero velero --no-headers 2>/dev/null | wc -l)
  velero_deployed=$(clean_number "$velero_deployed")

  if [ "$velero_deployed" -gt 0 ]; then
    success "Velero Backup installed"
    backups_scheduled=$(velero backup get 2>/dev/null | grep -c Scheduled || echo "0")
    backups_scheduled=$(clean_number "$backups_scheduled")
    info "Scheduled Backups: $backups_scheduled"
  else
    warn "No Velero backup installed!"
  fi

  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    volumesnapshots=$(kubectl get volumesnapshotcontents -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$volumesnapshots" -gt 0 ]; then
      info "$ns: $volumesnapshots Volume Snapshots available"
    fi
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# OBSERVABILITY STACK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function ObservabilityStack {
  print_header_second "OBSERVABILITY STACK"

  logging_installed=false
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

  grafana_running=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "grafana" || echo "0")
  if [ "$grafana_running" -gt 0 ]; then
    echo -e "${GREEN}Dashboards:${RESET} Grafana ($grafana_running Pods)"
  fi

  alertmanager_running=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "alertmanager" || echo "0")
  if [ "$alertmanager_running" -gt 0 ]; then
    echo -e "${GREEN}Alerting:${RESET} AlertManager ($alertmanager_running Pods)"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GITOPS / CI/CD INTEGRATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function GitOps {
  print_header_second "GITOPS / CI/CD INTEGRATION"

  argocd_installed=$(kubectl get namespace argocd --no-headers 2>/dev/null | wc -l)
  argocd_installed=$(clean_number "$argocd_installed")
  
  if [ "$argocd_installed" -gt 0 ]; then
    success "ArgoCD GitOps installed"
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
      hr_count=$(kubectl get helmrelease --all-namespaces --no-headers 2>/dev/null | wc -l)
      hr_count=$(clean_number "$hr_count")
      [ "$hr_count" -gt 0 ] && info "HelmReleases: $hr_count"
    fi
    
    if kubectl api-resources 2>/dev/null | grep -q "kustomization"; then
      ku_count=$(kubectl get kustomization --all-namespaces --no-headers 2>/dev/null | wc -l)
      ku_count=$(clean_number "$ku_count")
      [ "$ku_count" -gt 0 ] && info "Kustomizations: $ku_count"
    fi
  else
    info "Flux CD not found"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECRET MANAGEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function SecretManagement {
  print_header_second "SECRET SECURITY"

  total_secrets=$(kubectl get secrets --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  basic_secrets=$(kubectl get secrets --all-namespaces --no-headers 2>/dev/null | grep "Opaque" | wc -l | tr -d '[:space:]')

  info "Total Secrets: ${total_secrets:-0} | Opaque: ${basic_secrets:-0}"

  # External Secrets Operator - robust prüfen
  external_secret_output=$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c "external-secrets" 2>/dev/null || echo "0")
  external_secret_op=$(echo "$external_secret_output" | tr -d '[:space:]')
  [ -z "$external_secret_op" ] && external_secret_op=0

  if [ "$external_secret_op" -gt 0 ]; then
    success "External Secrets Controller active"
  else
    warn "No ExternalSecrets operator - manual secret management"
  fi

  # Sealed Secrets - ebenfalls robust
  sealed_secret_output=$(kubectl get deployment --all-namespaces --no-headers 2>/dev/null | grep -c "sealed-secrets" 2>/dev/null || echo "0")
  sealed_secrets=$(echo "$sealed_secret_output" | tr -d '[:space:]')
  [ -z "$sealed_secrets" ] && sealed_secrets=0

  if [ "$sealed_secrets" -gt 0 ]; then
    success "Sealed Secrets in use"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECURITY POLICIES & ADMISSION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function Security {
  print_header_second "SECURITY POLICIES & ADMISSION"

  gatekeeper=$(kubectl get deployment -n gatekeeper-system --no-headers 2>/dev/null | wc -l)
  gatekeeper=$(clean_number "$gatekeeper")
  [ "$gatekeeper" -gt 0 ] && success "OPA Gatekeeper active" || info "OPA Gatekeeper not found"

  kyverno=$(kubectl get deployment -n kyverno --no-headers 2>/dev/null | wc -l)
  kyverno=$(clean_number "$kyverno")
  [ "$kyverno" -gt 0 ] && success "Kyverno Policy Engine active" || info "Kyverno not found"

  admission_labeled=0
  for ns in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    psa=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    [ -n "$psa" ] && admission_labeled=$((admission_labeled + 1))
  done
  
  # total_ns muss GLOBAL sein (sieh NetworkPolicies oben)
  info "PSA labeled namespaces: $admission_labeled/$total_ns"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# EMERGENCY COMMANDS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PRODUCTION READINESS SCORE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function Score {
  print_header "PRODUCTION READINESS SCORE"

  score=0
  total_checks=12
  passed=0

  # Check 1: All Nodes Ready
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo "0")
  ready_nodes=$(clean_number "$ready_nodes")
  total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  total_nodes=$(clean_number "$total_nodes")
  if [ "$ready_nodes" = "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
    passed=$((passed + 1))
  fi

  # Check 2: No Critical Pod Issues
  critical_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -E 'Pending|Failed|Error' | wc -l || echo "0")
  critical_pods=$(clean_number "$critical_pods")
  if [ "$critical_pods" -eq 0 ]; then
    passed=$((passed + 1))
  fi

  # Check 3-12
  [ "$pdb_count" -gt 0 ] && ((passed++))
  [ "$hpa_count" -gt 0 ] && ((passed++))
  [ "$np_count" -gt 0 ] && ((passed++))
  [ "$velero_deployed" -gt 0 ] && ((passed++))
  [ -n "$privileged" ] || ((passed++))  
  [ "$admission_labeled" -gt 0 ] && ((passed++))
  [ "$quota_total" -gt 0 ] && ((passed++))
  [ "$argocd_installed" -gt 0 ] || [ "$flux_installed" -gt 0 ] && ((passed++))
  prom_ns=$(kubectl get namespace monitoring 2>/dev/null | grep -c "monitoring" || echo "0")
  prom_ns=$(clean_number "$prom_ns")
  [ "$prom_ns" -gt 0 ] && ((passed++))
  cp_issues=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -cv Running || echo "0")
  cp_issues=$(clean_number "$cp_issues")
  [ "$cp_issues" -eq 0 ] && ((passed++))

  # Score calculation
  score=$((passed * 100 / total_checks))

  case $score in
    90-100) score_color="$GREEN" ;;
    70-89)  score_color="$YELLOW" ;;
    *)      score_color="$RED" ;;
  esac

  echo -e "${BOLD}Score: ${score_color}${score}%${RESET} ($passed/$total_checks checks passed)"
  echo ""
  echo -e "${DIM}Cluster Production Check completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

####
ClusterInfo
HelmInfo
ControlPlaneHealth
CertificateExpiration
BackupStatus
ResourceQuotasLimits
PODSecurity
NetworkPolicies
ConfigRBAC
PODDisruptionBudgets
PODAutoscaling
ObservabilityStack
GitOps
SecretManagement
Security
#EmergencyCommands
Score