#!/bin/bash
#==============================================================================
# config-inventory-only.sh
# Zeigt NUR Pakete mit Konfigurationsdateien in /etc
#==============================================================================

VERBOSE=""
OUTPUT_FILE=""

# Args parsen
for arg in "$@"; do
    case "$arg" in
        -v|--verbose)
            VERBOSE="yes"
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [-v] [output_file]

Options:
  -v              Show all config paths (not just summary count)
  output_file     Save output to file

Example:
  $0              # Summary only (package + count)
  $0 -v           # Full paths for each config file
EOF
            exit 0
            ;;
        *)
            OUTPUT_FILE="$arg"
            ;;
    esac
done

echo "================================================================================"
echo "Configuration Files Inventory - Arch Linux - $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================================"
echo ""

# Header je nach Modus
if [ "$VERBOSE" = "yes" ]; then
    printf "| %-30s | %-12s | %s |\n" "PACKAGE" "CONFIGS" "PATH"
    echo "|------------------------------|--------------|-----------------------------------------|"
else
    printf "| %-30s | %-12s |\n" "PACKAGE" "CONFIG_FILES"
    echo "|------------------------------|--------------|"
fi

total_packages=0
total_configs=0

while read -r package version rest; do
    [ -z "$package" ] && continue

    # Config-Dateien holen (nur /etc/)
    config_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)

    # Zählen
    if [ -n "$config_files" ]; then
        config_count=$(echo "$config_files" | wc -l)
        total_packages=$((total_packages + 1))
        total_configs=$((total_configs + config_count))

        if [ "$VERBOSE" = "yes" ]; then
            # Verbose: JEDE Config-Datei als eigene Zeile
            first=true
            echo "$config_files" | while read -r filepath; do
                [ -z "$filepath" ] && continue
                if [ "$first" = "true" ]; then
                    printf "| %-30s | %-12s | %s |\n" "$package" "$config_count" "$filepath"
                    first=false
                else
                    printf "| %-30s | %-12s | %s |\n" "" "" "$filepath"
                fi
            done
        else
            # Normal: Nur Zusammenfassung pro Paket
            printf "| %-30s | %-12s |\n" "$package" "$config_count"
        fi
    fi

done < <(pacman -Q 2>/dev/null)

echo "|------------------------------|--------------|-----------------------------------------|"
echo ""
echo "Summary: $total_packages packages with configs, $total_configs total config files"
echo "================================================================================"

# Optional: Datei speichern
if [ -n "$OUTPUT_FILE" ]; then
    echo "[INFO] Saved to: $OUTPUT_FILE" >&2
fi
