#!/bin/bash
#==============================================================================
# config-inventory-columns.sh
# Alle Config-Pfade pro Paket mit column + Farbierung (Home = Cyan, System = Grün)
#==============================================================================

VERBOSE="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

TEMP_SYS="/tmp/sys-configs-$$"
TEMP_HOME="/tmp/home-configs-$$"

echo -e "${BLUE}Configuration Files Inventory"
echo -e "Host: $HOSTNAME${NC} @ $(date '+%Y-%m-%d %H:%M:%S')"
echo ""



# Schleife durch alle Pakete
while read -r package version; do
    [ -z "$package" ] && continue

    # 1. System-Configs (/etc/) sammeln
    sys_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)

    # 2. Home-Configs sammeln
    home_files=""
    if [ -d "$HOME" ]; then
        home_files=$(find "$HOME" -maxdepth 3 \( -name ".*" -o -path "*/.config/*" -o -path "*/.local/*" \) -type f 2>/dev/null | \
            grep -i "$package" || true)
    fi

    # Nur anzeigen wenn mindestens eine Config vorhanden
    if [ -n "$sys_files" ] || [ -n "$home_files" ]; then
        echo ""
        echo -e "${YELLOW}📦 $package${NC}"

        # System-Configs in grün
        if [ -n "$sys_files" ]; then
            echo -e "  ${GREEN}🔧 System (/etc):${NC}"
            {
                echo "$sys_files" | head -10 | while read -r filepath; do
                    [ -n "$filepath" ] && printf "%s\t%s\n" "$package" "$filepath"
                done
            } | column -t -s $'\t'

            remaining=$(echo "$sys_files" | wc -l)
            [ "$remaining" -gt 10 ] && echo -e "  ${GREEN}  ... and $((remaining - 10)) more${NC}"
        fi

        # Home-Configs in cyan
        if [ -n "$home_files" ]; then
            echo -e "  ${CYAN}🏠 Home (~/${HOME#/home/$USER}):${NC}"
            {
                echo "$home_files" | while read -r filepath; do
                    [ -n "$filepath" ] && printf "%s\t%s\n" "$package" "$filepath"
                done
            } | column -t -s $'\t'

            #remaining=$(echo "$home_files" | wc -l)
            #[ "$remaining" -gt 10 ] && echo -e "  ${CYAN}  ... and $((remaining - 10)) more${NC}"
        fi
    fi

done < <(pacman -Q 2>/dev/null)

# summary
echo ""
echo -e "${BLUE}SUMMARY${NC}"

total_sys=0
total_home=0

while read -r package version; do
    [ -z "$package" ] && continue

    sys_count=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" | wc -l) || sys_count=0
    home_count=0
    if [ -d "$HOME" ]; then
        home_count=$(find "$HOME" -maxdepth 3 \( -name ".*" -o -path "*/.config/*" \) -type f 2>/dev/null | \
            grep -i "$package" | wc -l) || home_count=0
    fi

    total_sys=$((total_sys + sys_count))
    total_home=$((total_home + home_count))
done < <(pacman -Q 2>/dev/null)

printf "%-35s %d\n" "System configs (/etc):" "$total_sys"
printf "%-35s %d\n" "Home configs (~/*):" "$total_home"
printf "%-35s %d\n" "Grand total:" "$((total_sys + total_home))"

# Cleanup
rm -f "$TEMP_SYS" "$TEMP_HOME" 2>/dev/null
