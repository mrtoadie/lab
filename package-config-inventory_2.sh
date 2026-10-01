#!/bin/bash
#==============================================================================
# config-inventory-columns.sh
# Alle Config-Pfade pro Paket mit column + Farbierung
#
# usage:
#   ./config-inventory-columns.sh          # Auto-Erkennung (farbig im Terminal)
#   ./config-inventory-columns.sh > out.txt # Clean text (keine Farben)
#   COLORED=force ./config-inventory-columns.sh | less -R  # Force colors
#==============================================================================

VERBOSE="${1:-}"

#==============================================================================
# COLOR LOGIC - Auto-detect TTY + Manual Override
#==============================================================================
# Umgebungsvariable: COLORED=auto (default), force, off
COLORED="${COLORED:-auto}"

if [ "$COLORED" = "off" ]; then
    # Farben explizit deaktiviert
    USE_COLORS=0
elif [ "$COLORED" = "force" ]; then
    # Farben erzwingen (für piping in less -R o.ä.)
    USE_COLORS=1
elif [ -t 1 ]; then
    # STDOUT ist Terminal → Farben AN
    USE_COLORS=1
else
    # STDOUT wird umgelenkt → Farben AUS
    USE_COLORS=0
fi

# Farb-Definitionen bedingt setzen
if [ "$USE_COLORS" -eq 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m' # No Color
else
    # Keine Farben für Datei-Ausgabe
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; NC=''
fi

# Hilfsfunktionen für konsistente Ausgabe
print_header() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${BLUE}${1}${NC}"
    else
        echo "--- ${1} ---"
    fi
}

print_section() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${YELLOW}${1}${NC}"
    else
        echo "[${1}]"
    fi
}

print_system() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "  ${GREEN}${1}${NC}"
    else
        echo "  SYSTEM: ${1}"
    fi
}

print_home() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "  ${CYAN}${1}${NC}"
    else
        echo "  HOME: ${1}"
    fi
}

print_summary_label() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${BLUE}${1}${NC}"
    else
        echo "${1}"
    fi
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

print_header "Configuration Files Inventory"
echo "Host: $HOSTNAME @ $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Temporäre Dateien für Zwischenspeicher
TEMP_SYS="/tmp/sys-configs-$$"
TEMP_HOME="/tmp/home-configs-$$"

trap "rm -f '$TEMP_SYS' '$TEMP_HOME'" EXIT

# Counter für Summary
total_sys=0
total_home=0
packages_with_configs=0

# Schleife durch alle Pakete
while read -r package version; do
    [ -z "$package" ] && continue

    # 1. System-Configs (/etc/) sammeln
    sys_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)

    # Nur /etc Dateien zählen, nicht Verzeichnisse
    sys_file_count=$(echo "$sys_files" | grep -v '/$' | wc -l) || sys_file_count=0

    # 2. Home-Configs sammeln
    home_files=""
    if [ -d "$HOME" ]; then
        home_files=$(find "$HOME" -maxdepth 3 \
            \( -name ".*" -o -path "*/.config/*" -o -path "*/.local/state/*" -o -path "*/.local/share/*" \) \
            -type f 2>/dev/null | grep -i "$package" || true)
    fi

    home_file_count=$(echo "$home_files" | grep -c '.' 2>/dev/null) || home_file_count=0

    # Nur anzeigen wenn mindestens eine Config vorhanden
    if [ "$sys_file_count" -gt 0 ] || [ "$home_file_count" -gt 0 ]; then
        packages_with_configs=$((packages_with_configs + 1))

        print_section "📦 $package"

        # System-Configs
        if [ "$sys_file_count" -gt 0 ]; then
            print_system "🔧 System (/etc):"

            # Erste 10 Dateien anzeigen
            echo "$sys_files" | grep -v '/$' | head -10 | while read -r filepath; do
                [ -n "$filepath" ] && printf "%-25s %s\n" "$package" "$filepath"
            done | column -t -s $'\t' 2>/dev/null || echo "$sys_files" | grep -v '/$' | head -10

            remaining=$((sys_file_count - 10))
            [ "$remaining" -gt 0 ] && print_system "  ... and $remaining more"

            total_sys=$((total_sys + sys_file_count))
        fi

        # Home-Configs
        if [ "$home_file_count" -gt 0 ]; then
            print_home "🏠 Home (~):"

            echo "$home_files" | while read -r filepath; do
                [ -n "$filepath" ] && printf "%-25s %s\n" "$package" "$filepath"
            done | column -t -s $'\t' 2>/dev/null || echo "$home_files"

            total_home=$((total_home + home_file_count))
        fi

        echo ""
    fi

done < <(pacman -Q 2>/dev/null)

#==============================================================================
# SUMMARY
#==============================================================================

print_header "SUMMARY"
printf "%-35s %d\n" "Packages with configs:" "$packages_with_configs"
printf "%-35s %d\n" "System configs (/etc):" "$total_sys"
printf "%-35s %d\n" "Home configs (~):" "$total_home"
printf "%-35s %d\n" "Grand total:" "$((total_sys + total_home))"

#==============================================================================
# HINT FOR FILE OUTPUT
#==============================================================================

if [ "$USE_COLORS" -eq 0 ]; then
    echo ""
    echo "# Tip: Für farbige Ausgabe im Terminal:" >&2
    echo "#   ./$(basename "$0")" >&2
    echo "# Für geforceerde Farben mit less:" >&2
    echo "#   COLORED=force ./$(basename "$0") | less -R" >&2
fi

exit 0
