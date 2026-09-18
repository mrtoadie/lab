#!/bin/bash
#==============================================================================
# config-inventory-only.sh - MIT COLUMN FORMATIERUNG
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

if [ "$VERBOSE" = "yes" ]; then
    # Verbose Mode mit column
    {
        printf "PACKAGE\tCONFIGS\tPATH\n"
        
        while read -r package version rest; do
            [ -z "$package" ] && continue
            
            config_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)
            
            if [ -n "$config_files" ]; then
                config_count=$(echo "$config_files" | wc -l)
                
                first=true
                echo "$config_files" | while read -r filepath; do
                    [ -z "$filepath" ] && continue
                    if [ "$first" = "true" ]; then
                        printf "%s\t%s\t%s\n" "$package" "$config_count" "$filepath"
                        first=false
                    else
                        printf "%s\t%s\t%s\n" "" "" "$filepath"
                    fi
                done
            fi
        done < <(pacman -Q 2>/dev/null)
    } | column -t -s $'\t'
        
    # Gesamtrechnung separat
    total_pkg=0
    total_cfg=0
    while read -r package version rest; do
        [ -z "$package" ] && continue
        config_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)
        if [ -n "$config_files" ]; then
            total_pkg=$((total_pkg + 1))
            total_cfg=$((total_cfg + $(echo "$config_files" | wc -l)))
        fi
    done < <(pacman -Q 2>/dev/null)
    
    echo "--------------------------------------------------------------------------------"
    echo "Summary: $total_pkg packages with configs, $total_cfg total config files"
    echo "(Showing first 50 entries)"
    
else
    # Normaler Modus mit column
    {
        printf "PACKAGE\tCONFIG_FILES\n"
        
        while read -r package version rest; do
            [ -z "$package" ] && continue
            
            config_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)
            
            if [ -n "$config_files" ]; then
                config_count=$(echo "$config_files" | wc -l)
                printf "%s\t%d\n" "$package" "$config_count"
            fi
        done < <(pacman -Q 2>/dev/null)
    } | column -t -s $'\t'
    
    # Gesamtrechnung
    total_pkg=0
    total_cfg=0
    while read -r package version rest; do
        [ -z "$package" ] && continue
        config_files=$(pacman -Ql "$package" 2>/dev/null | awk '{print $2}' | grep "^/etc/" || true)
        if [ -n "$config_files" ]; then
            total_pkg=$((total_pkg + 1))
            total_cfg=$((total_cfg + $(echo "$config_files" | wc -l)))
        fi
    done < <(pacman -Q 2>/dev/null)
    
    echo ""
    echo "================================================================================"
    echo "Total: $total_pkg packages with configs, $total_cfg total config files"
    echo "================================================================================"
fi

# Optional: Datei speichern
if [ -n "$OUTPUT_FILE" ]; then
    echo "[INFO] Saved to: $OUTPUT_FILE" >&2
fi
