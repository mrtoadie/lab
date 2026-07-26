#!/usr/bin/env bash
# /usr/local/bin/rpi-control.sh

HOSTS=(
    "192.168.178.210"
    "192.168.178.212"
    "192.168.178.214"
)
USER="toadie"

# Icons - verschiedene Optionen verfügbar:
SHUTDOWN_ICON="⏻"     # Unicode Power Symbol (IEC standardisiert)
# SHUTDOWN_ICON="🛑"   # Stop-Schild
# SHUTDOWN_ICON="💤"   # Schlafmodus
# SHUTDOWN_ICON="⏼"   # Power On/Off Symbol

ping_hosts() {
    echo "📡 Checking hosts..."
    echo ""
    for i in "${!HOSTS[@]}"; do
        host="${HOSTS[$i]}"
        num=$((i + 1))
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            printf "✅ [%d] %s is UP\n" "$num" "$host"
        else
            printf "❌ [%d] %s is DOWN\n" "$num" "$host"
        fi
    done
    echo ""
}

shutdown_host() {
    local index=$1
    local host="${HOSTS[$((index - 1))]}"
    
    if [[ -z "$host" ]]; then
        printf "${RED}❌ Ungültige Auswahl!${NC}\n"
        return 1
    fi
    
    printf "${SHUTDOWN_ICON}  Shutting down %s...\n" "$host"
    
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$host" "sudo shutdown -h now" 2>/dev/null; then
        printf "✅ %s shutdown command sent\n" "$host"
    else
        printf "⚠️  Could not reach %s (check SSH/connectivity)\n" "$host"
    fi
}

shutdown_all_hosts() {
    echo "⚠️  This will shut down ALL reachable hosts!"
    read -p "Continue? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return 0
    fi
    
    local success=0
    local failed=0
    
    for i in "${!HOSTS[@]}"; do
        host="${HOSTS[$i]}"
        num=$((i + 1))
        
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            printf "${SHUTDOWN_ICON}  Shutting down [%d] %s...\n" "$num" "$host"
            
            if ssh -o ConnectTimeout=5 "$USER@$host" "sudo shutdown -h now" 2>/dev/null; then
                printf "✅ [%d] %s shutdown initiated\n" "$num" "$host"
                ((success++))
            else
                printf "❌ [%d] %s failed\n" "$num" "$host"
                ((failed++))
            fi
        else
            printf "⚠️  [%d] %s unreachable, skipped\n" "$num" "$host"
        fi
        
        sleep 1
    done
    
    echo ""
    printf "Summary: ${success} succeeded, ${failed} failed\n"
}

interactive_menu() {
    while true; do
        echo "╔════════════════════════════════════════╗"
        echo "║     Raspberry Pi Control Panel         ║"
        echo "╠════════════════════════════════════════╣"
        echo "║  1. Ping all hosts                     ║"
        echo "║  2. Selective shutdown                 ║"
        echo "║  3. Shutdown ALL hosts                 ║"
        echo "║  4. Exit                               ║"
        echo "╚════════════════════════════════════════╝"
        echo ""
        read -p "Selection [1-4]: " choice
        
        case $choice in
            1)
                ping_hosts
                ;;
            2)
                echo ""
                ping_hosts
                echo "${SHUTDOWN_ICON}  Select host number to shutdown:"
                read -p "Enter number (or 'a' for all, 'q' to cancel): " sel
                
                case $sel in
                    a|A)
                        shutdown_all_hosts
                        ;;
                    q|Q|quit)
                        echo "Cancelled."
                        ;;
                    [1-9]*)
                        shutdown_host "$sel"
                        ;;
                    *)
                        echo "Invalid selection."
                        ;;
                esac
                ;;
            3)
                shutdown_all_hosts
                ;;
            4)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid option. Try again."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        clear
    done
}

cmdline_shutdown() {
    local selections="$1"
    
    # Komma-separated Liste verarbeiten (z.B. 1,3 oder 1,2,3)
    IFS=',' read -ra indices <<< "$selections"
    
    for idx in "${indices[@]}"; do
        # Leerzeichen entfernen
        idx=$(echo "$idx" | tr -d ' ')
        
        if [[ "$idx" == "all" ]] || [[ "$idx" == "*" ]]; then
            shutdown_all_hosts
            break
        fi
        
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            shutdown_host "$idx"
        fi
    done
}

show_help() {
    cat << EOF
Usage: $0 [command]

Commands:
  ping                  Check all hosts
  shutdown              Interactive menu
  shutdown <list>       Shutdown specific hosts (comma-separated, e.g. "1,3")
  shutdown all          Shutdown all reachable hosts
  help                  Show this help

Examples:
  $0 ping
  $0 shutdown
  $0 shutdown 1
  $0 shutdown 1,3
  $0 shutdown all
EOF
}

# Main
case "${1:-}" in
    ping)
        ping_hosts
        ;;
    shutdown)
        if [[ -n "${2:-}" ]]; then
            cmdline_shutdown "$2"
        else
            interactive_menu
        fi
        ;;
    interactive)
        interactive_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        interactive_menu
        ;;
    *)
        echo "Unknown command: ${1}"
        show_help
        exit 1
        ;;
esac
