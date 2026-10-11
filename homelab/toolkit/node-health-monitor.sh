#!/bin/bash

# ============================================
# k3s Node Health Monitor
# Usage: ./node-health-monitor.sh [nodes...]
# ============================================

# Farbdefinitionen
COL_RESET="\033[0m"
COL_GREEN="\033[32m"
COL_YELLOW="\033[33m"
COL_RED="\033[31m"
COL_BLUE="\033[34m"
COL_CYAN="\033[36m"

# Schwellenwerte (%)
CPU_WARN=70
CPU_CRIT=90
MEM_WARN=70
MEM_CRIT=90
DISK_WARN=80
DISK_CRIT=95
TEMP_WARN=70
TEMP_CRIT=85

# Standard Nodes (anpassbar)
DEFAULT_NODES=("192.168.178.210" "192.168.178.212" "192.168.178.214" "192.168.178.216")
NODES="${@:-${DEFAULT_NODES[*]}}"

# Funktion: CPU Auslastung prüfen
check_cpu() {
    local node=$1
    local cpu=$(ssh "$node" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1 2>/dev/null || echo 0" 2>/dev/null)
    
    if [ -z "$cpu" ]; then
        echo -e "${COL_RED}N/A${COL_RESET}"
        return 1
    fi
    
    # Ganzzahl extrahieren
    cpu_int=${cpu%.*}
    
    if [ "$cpu_int" -ge "$CPU_CRIT" ]; then
        echo -e "${COL_RED}${cpu}%${COL_RESET}"
        return 2
    elif [ "$cpu_int" -ge "$CPU_WARN" ]; then
        echo -e "${COL_YELLOW}${cpu}%${COL_RESET}"
        return 1
    else
        echo -e "${COL_GREEN}${cpu}%${COL_RESET}"
        return 0
    fi
}

# Funktion: RAM Auslastung prüfen
check_memory() {
    local node=$1
    local mem_info=$(ssh "$node" "free | grep Mem | awk '{printf \"%.1f\", (\$3/\$2)*100}' 2>/dev/null" 2>/dev/null)
    
    if [ -z "$mem_info" ]; then
        echo -e "${COL_RED}N/A${COL_RESET}"
        return 1
    fi
    
    mem_int=${mem_info%.*}
    
    if [ "$mem_int" -ge "$MEM_CRIT" ]; then
        echo -e "${COL_RED}${mem_info}%${COL_RESET}"
        return 2
    elif [ "$mem_int" -ge "$MEM_WARN" ]; then
        echo -e "${COL_YELLOW}${mem_info}%${COL_RESET}"
        return 1
    else
        echo -e "${COL_GREEN}${mem_info}%${COL_RESET}"
        return 0
    fi
}

# Funktion: Disk Auslastung prüfen (Root partition)
check_disk() {
    local node=$1
    local disk=$(ssh "$node" "df -h / | tail -1 | awk '{print \$5}' | tr -d '%' 2>/dev/null" 2>/dev/null)
    
    if [ -z "$disk" ]; then
        echo -e "${COL_RED}N/A${COL_RESET}"
        return 1
    fi
    
    if [ "$disk" -ge "$DISK_CRIT" ]; then
        echo -e "${COL_RED}${disk}%${COL_RESET}"
        return 2
    elif [ "$disk" -ge "$DISK_WARN" ]; then
        echo -e "${COL_YELLOW}${disk}%${COL_RESET}"
        return 1
    else
        echo -e "${COL_GREEN}${disk}%${COL_RESET}"
        return 0
    fi
}

# Funktion: Temperatur prüfen (CPU Temp)
check_temp() {
    local node=$1
    local temp=$(ssh "$node" "cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 | awk '{print \$1/1000}' 2>/dev/null" 2>/dev/null)
    
    if [ -z "$temp" ]; then
        echo -e "${COL_CYAN}N/A${COL_RESET}"
        return 0
    fi
    
    temp_int=${temp%.*}
    
    if [ "$temp_int" -ge "$TEMP_CRIT" ]; then
        echo -e "${COL_RED}${temp}°C${COL_RESET}"
        return 2
    elif [ "$temp_int" -ge "$TEMP_WARN" ]; then
        echo -e "${COL_YELLOW}${temp}°C${COL_RESET}"
        return 1
    else
        echo -e "${COL_GREEN}${temp}°C${COL_RESET}"
        return 0
    fi
}

# Funktion: k3s Service Status prüfen
check_k3s() {
    local node=$1
    local status=$(ssh "$node" "systemctl is-active k3s 2>/dev/null" 2>/dev/null)
    
    if [ "$status" == "active" ]; then
        echo -e "${COL_GREEN}Active${COL_RESET}"
        return 0
    elif [ -n "$status" ]; then
        echo -e "${COL_RED}$status${COL_RESET}"
        return 2
    else
        echo -e "${COL_CYAN}N/A${COL_RESET}"
        return 0
    fi
}

# Funktion: Kubernetes Node Status prüfen
check_k8s_node() {
    local node=$1
    local k8s_status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[-1]{.status}}' 2>/dev/null)
    
    if [ "$k8s_status" == "True" ]; then
        echo -e "${COL_GREEN}Ready${COL_RESET}"
        return 0
    elif [ -n "$k8s_status" ]; then
        echo -e "${COL_RED}NotReady${COL_RESET}"
        return 2
    else
        echo -e "${COL_YELLOW}Unknown${COL_RESET}"
        return 1
    fi
}

# Hauptfunktion: Alle Checks zusammenführen
run_health_check() {
    printf "\n${COL_BLUE}╔═══════════════════════════════════════════════════════════════╗${COL_RESET}\n"
    printf "${COL_BLUE}║           %s          ║${COL_RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${COL_BLUE}╠═══════════════════════════════════════════════════════════════╣${COL_RESET}\n"
    printf "${COL_BLUE}║ %-12s │ %8s │ %8s │ %6s │ %6s │ %6s │ ${COL_RESET}\n" "NODE" "CPU" "MEMORY" "DISK" "TEMP" "STATUS"
    printf "${COL_BLUE}╠═══════════════════════════════════════════════════════════════╣${COL_RESET}\n"
    
    local failed_nodes=0
    local total_nodes=0
    
    for node in $NODES; do
        total_nodes=$((total_nodes + 1))
        
        # SSH Connection Test zuerst
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" "exit" 2>/dev/null; then
            printf "${COL_RED}║ %-12s │ %8s │ %8s │ %6s │ %6s │ %6s │${COL_RESET}\n" \
                "$node" "TIMEOUT" "TIMEOUT" "TIMEOUT" "TIMEOUT" "DOWN"
            failed_nodes=$((failed_nodes + 1))
            continue
        fi
        
        # Alle Metriken sammeln
        local cpu_result=$(check_cpu "$node"; true)
        local cpu_exit=$?
        
        local mem_result=$(check_memory "$node"; true)
        local mem_exit=$?
        
        local disk_result=$(check_disk "$node"; true)
        local disk_exit=$?
        
        local temp_result=$(check_temp "$node"; true)
        local temp_exit=$?
        
        local k8s_result=$(check_k8s_node "$node"; true)
        local k8s_exit=$?
        
        # Node Status basierend auf allen Exit Codes bestimmen
        local node_status="OK"
        if [ $((cpu_exit + mem_exit + disk_exit + k8s_exit)) -gt 0 ]; then
            node_status="WARN"
            if [ $((cpu_exit + mem_exit + disk_exit + k8s_exit)) -gt 4 ]; then
                node_status="CRIT"
            fi
        fi
        
        # Zeile rendern
        printf "║ %-12s │ %8s │ %8s │ %6s │ %6s │ %6s │\n" \
            "$node" "$cpu_result" "$mem_result" "$disk_result" "$temp_result" "$k8s_result"
    done
    
    printf "${COL_BLUE}╠═══════════════════════════════════════════════════════════════╣${COL_RESET}\n"
    printf "${COL_BLUE}║ Summary:     ${COL_GREEN}%d${COL_RESET} OK    ${COL_YELLOW}%d${COL_RESET} WARN    ${COL_RED}%d${COL_RESET} CRIT                  ║\n" \
        "$((total_nodes - failed_nodes - $(echo "$NODES" | tr ' ' '\n' | while read n; do check_k8s_node "$n" > /dev/null 2>&1 && [ $? -eq 0 ] && echo x; done | wc -l)))" \
        "0" \
        "$failed_nodes"
    printf "${COL_BLUE}╚═══════════════════════════════════════════════════════════════╝${COL_RESET}\n\n"
    
    # Warnungen ausgeben
    if [ $failed_nodes -gt 0 ]; then
        echo -e "${COL_RED}⚠ $failed_nodes Node(s) unreachable or in critical state${COL_RESET}"
    fi
}

# Optionen parse
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 [node1] [node2] ..."
            echo "       $0 --nodes winterfell worker01 worker02"
            echo ""
            echo "Environment variables:"
            echo "  NODES_DEFAULT  - Komma-separierte Liste von Nodes"
            exit 0
            ;;
        --nodes)
            NODES="$2"
            shift 2
            ;;
        *)
            NODES="$*"
            shift
            ;;
    esac
done

# Ausführen
run_health_check
