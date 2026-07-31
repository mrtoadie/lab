#!/bin/bash
# k3s-context-manager.sh
# Verwaltet den Wechsel zwischen Desktop- und k3s Cluster-Context

set -euo pipefail

# Konfiguration
K3S_MASTER_IP="192.168.178.210"
K3S_USERNAME="toadie"
K3S_KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
LOCAL_KUBECONFIG="$HOME/.kube/config"
K3S_KUBECONFIG="$HOME/.kube/k3s.yaml"

# Farbcodes (FIXED: RESET statt COLOR_RESET)
COLOR_RESET='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'

# Hilfsfunktionen mit korrekter Variablennutzung
print_success() { echo -e "${GREEN}✓ $1${COLOR_RESET}"; }
print_warn() { echo -e "${YELLOW}⚠ $1${COLOR_RESET}"; }
print_error() { echo -e "${RED}✗ $1${COLOR_RESET}"; }
print_info() { echo -e "${CYAN}ℹ $1${COLOR_RESET}"; }

show_menu() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  Kubernetes Context Switcher             ║"
    echo "╠══════════════════════════════════════════╣"
    echo "║  1) Wechsel zu k3s Cluster (Pi)          ║"
    echo "║  2) Wechsel zu Desktop Cluster           ║"
    echo "║  3) Aktuelle Contexts anzeigen           ║"
    echo "║  4) Alle Contexts auflisten              ║"
    echo "║  5) k3s Config neu holen                 ║"
    echo "║  0) Beenden                              ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

get_current_context() {
    kubectl config current-context 2>/dev/null || echo "none"
}

switch_to_k3s() {
    print_info "Verbinde mit k3s Master (${K3S_MASTER_IP})..."

    # SSH-Test
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${K3S_USERNAME}@${K3S_MASTER_IP}" exit 2>/dev/null; then
        print_warn "SSH-Verbindung nicht getestet, versuche trotzdem..."
    fi

    # Kubeconfig kopieren
    print_info "Kopiere k3s Kubeconfig..."
    scp -q "${K3S_USERNAME}@${K3S_MASTER_IP}:${K3S_KUBECONFIG_PATH}" "${K3S_KUBECONFIG}" || {
        print_error "Fehler beim Kopieren der Kubeconfig!"
        exit 1
    }
    print_success "Kubeconfig kopiert"

    # IP anpassen
    print_info "Anpassen der Server-IP..."
    sed -i "s|127.0.0.1|${K3S_MASTER_IP}|g" "${K3S_KUBECONFIG}"
    sed -i "s|localhost|${K3S_MASTER_IP}|g" "${K3S_KUBECONFIG}"
    print_success "IP angepasst"

    # KUBECONFIG Variable setzen
    export KUBECONFIG="${LOCAL_KUBECONFIG}:${K3S_KUBECONFIG}"

    # Context wechseln
    print_info "Wechsle zu k3s Context..."
    kubectl config use-context "k3s-default" 2>/dev/null || {
        print_warn "Context 'k3s-default' nicht gefunden, versuche anderen..."
        ctx=$(kubectl config get-contexts -o name 2>/dev/null | grep -E "k3s|default" | head -1)
        [ -n "$ctx" ] && kubectl config use-context "$ctx"
    }

    # Verifikation
    print_info "Verifikation..."
    if kubectl get nodes >/dev/null 2>&1; then
        print_success "Switch zu k3s erfolgreich!"
        echo ""
        kubectl get nodes -o wide | column -t
    else
        print_error "Verbindung zu k3s fehlgeschlagen!"
        exit 1
    fi
}

switch_to_desktop() {
    export KUBECONFIG="${LOCAL_KUBECONFIG}"
    
    local desktop_ctx=$(kubectl config get-contexts -o name 2>/dev/null | head -1)
    
    if [ -n "$desktop_ctx" ]; then
        kubectl config use-context "$desktop_ctx"
        print_success "Wechsel zu Desktop-Context ($desktop_ctx)"
    else
        print_warn "Kein Desktop-Context gefunden"
    fi

    kubectl get nodes 2>/dev/null || print_info "Keine Nodes verfügbar (lokal)"
}

show_current() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "  AKTUELLER CONTEXT"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Context:     $(get_current_context)"
    echo "KUBECONFIG:  $KUBECONFIG"
    echo ""
    kubectl config view --minify
}

list_all() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "  ALLE VERFÜGBAREN CONTEXTS"
    echo "═══════════════════════════════════════"
    echo ""
    kubectl config get-contexts
    echo ""
    kubectl config get-clusters
}

refresh_k3s_config() {
    print_info "Neues Herunterladen der k3s Kubeconfig..."
    rm -f "${K3S_KUBECONFIG}"
    switch_to_k3s
}

# Haupt-Logik
case "${1:-}" in
    "k3s"|"-k"|"--k3s")
        switch_to_k3s
        ;;
    "desktop"|"-d"|"--desktop")
        switch_to_desktop
        ;;
    "current"|"-c"|"--current")
        show_current
        ;;
    "list"|"-l"|"--list")
        list_all
        ;;
    "help"|"-h"|"--help")
        echo "Verwendung:"
        echo "  $0 [k3s|desktop|current|list|help]"
        echo ""
        echo "Optionen:"
        echo "  k3s      - Wechsel zu k3s Cluster"
        echo "  desktop  - Wechsel zu Desktop Cluster"
        echo "  current  - Zeige aktuellen Context"
        echo "  list     - Liste alle Contexts"
        echo "  help     - Diese Hilfe"
        ;;
    *)
        show_menu
        read -p "Auswahl: " choice
        case "$choice" in
            1) switch_to_k3s ;;
            2) switch_to_desktop ;;
            3) show_current ;;
            4) list_all ;;
            5) refresh_k3s_config ;;
            0) exit 0 ;;
            *) print_error "Ungültige Auswahl"; exit 1 ;;
        esac
        ;;
esac
