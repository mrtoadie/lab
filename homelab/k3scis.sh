#!/bin/bash
# k3s-cis-remediation.sh — CIS Benchmark Fixes für K3s Nodes
# Autor: toadie | Für: k3s auf Raspberry Pi

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== K3s CIS Benchmark Remediation ===${NC}"
echo "Startzeit: $(date)"

###############################################
# PHASE 1: Datei-Berechtigungen (4.1.3 - 4.1.8)
###############################################

echo -e "\n${YELLOW}[PHASE 1] Datei-Berechtigungen prüfen und reparieren${NC}"

declare -A FILES=(
    ["/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig"]="600 root:root"
    ["/var/lib/rancher/k3s/agent/kubelet.kubeconfig"]="600 root:root"
    ["/var/lib/rancher/k3s/agent/client-ca.crt"]="600 root:root"
)

for file in "${!FILES[@]}"; do
    if [[ -f "$file" ]]; then
        perms="${FILES[$file]%% *}"
        owner="${FILES[$file]##* }"
        
        current_perms=$(stat -c "%a" "$file" 2>/dev/null || echo "unknown")
        current_owner=$(stat -c "%U:%G" "$file" 2>/dev/null || echo "unknown")
        
        if [[ "$current_perms" != "$perms" || "$current_owner" != "$owner" ]]; then
            echo -e "${YELLOW}Korrektur: $file ($current_perms/$current_owner → $perms/$owner)${NC}"
            sudo chmod "$perms" "$file"
            sudo chown "$owner" "$file"
            echo -e "${GREEN}✓ Fertig${NC}"
        else
            echo -e "${GREEN}✓ Bereits korrekt: $file${NC}"
        fi
    else
        echo -e "${RED}⚠ Datei nicht gefunden (optional): $file${NC}"
    fi
done

###############################################
# PHASE 2: kubelet read-only-port (4.2.4)
###############################################

echo -e "\n${YELLOW}[PHASE 2] read-only-port prüfen${NC}"

if [[ -f /etc/rancher/k3s/config.yaml ]]; then
    if grep -q "read-only-port" /etc/rancher/k3s/config.yaml; then
        echo -e "${RED}WARN: read-only-port gefunden im config.yaml${NC}"
        echo "Bitte manuell entfernen:"
        echo "  1. Bearbeite: /etc/rancher/k3s/config.yaml"
        echo "  2. Lösche Zeilen mit 'read-only-port'"
        echo "  3. Neustart: sudo systemctl restart k3s"
    else
        echo -e "${GREEN}✓ read-only-port ist nicht konfiguriert (Standard=0)${NC}"
    fi
fi

###############################################
# PHASE 3: TLS Cipher Suites (4.2.12)
###############################################

echo -e "\n${YELLOW}[PHASE 3] TLS Cipher Suites konfigurieren (optional)${NC}"
read -p "Starke Ciphers konfigurieren? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    CIPHERS="TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
    
    if ! grep -q "tls-cipher-suites" /etc/rancher/k3s/config.yaml 2>/dev/null; then
        echo "kubelet-arg:" >> /etc/rancher/k3s/config.yaml
        echo "  - \"tls-cipher-suites=$CIPHERS\"" >> /etc/rancher/k3s/config.yaml
        echo -e "${GREEN}✓ Ciphers hinzugefügt${NC}"
        echo -e "${YELLOW}Neustart erforderlich: sudo systemctl restart k3s${NC}"
    else
        echo -e "${GREEN}✓ TLS Ciphers bereits konfiguriert${NC}"
    fi
fi

###############################################
# PHASE 4: RBAC Hardening (5.1.x) — MASTER NODE
###############################################

if systemctl is-active --quiet k3s && [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    echo -e "\n${YELLOW}[PHASE 4] RBAC auf Master Node prüfen${NC}"
    
    # 5.1.1: cluster-admin Bindings auflisten
    echo -e "${YELLOW}cluster-admin ClusterRoleBindings:${NC}"
    kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "Keine gefunden"
    
    # 5.1.3: Wildcards finden
    echo -e "\n${YELLOW}ClusterRoles mit Wildcards (${RED}prüfung notwendig${NC}):"
    kubectl get clusterroles -o json 2>/dev/null | jq -r '.items[] | select(.rules[]?.verbs[]? == "*" or .rules[]?.resources[]? == "*") | "\(.metadata.name)"' || echo "jq nicht installiert oder keine Wildcards"
    
    # 5.1.5: Default ServiceAccounts härten
    echo -e "\n${YELLOW}Default ServiceAccounts härten...${NC}"
    NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for ns in $NAMESPACES; do
        kubectl patch serviceaccount --namespace "$ns" default \
            --patch '{"automountServiceAccountToken": false}' 2>/dev/null && \
            echo "  ✓ $ns" || echo "  ⚠ $ns (bereits vorhanden/Fehler)"
    done
    
else
    echo -e "${RED}⚠ Ist kein Master Node (k3s Server), RBAC überspringen${NC}"
fi

###############################################
# ZUSAMMENFASSUNG
###############################################

echo -e "\n${YELLOW}=== Remediation abgeschlossen ===${NC}"
echo "Endzeit: $(date)"
echo ""
echo "Empfohlene nächste Schritte:"
echo "  1. kubectl rollout restart deployment --all --namespace=default (falls nötig)"
echo "  2. kube-bench erneut ausführen zur Validierung"
echo "  3. k3s-Dienste neu starten wo angefordert"
echo ""
echo -e "${GREEN}Skript erfolgreich ausgeführt!${NC}"
