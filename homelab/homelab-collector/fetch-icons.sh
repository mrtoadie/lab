#!/usr/bin/env bash
#
# fetch-icons.sh - pulls the dashboard icons from the Iconify API and stores
# them as local SVG files in assets/icons/.
#
#   ./scripts/fetch-icons.sh
#
# Afterwards the page makes zero external requests. Re-run it whenever you
# change the list below or want a fresher version of an icon.
#
# Requires: bash 4+ (associative arrays), curl
#
# Note on colours: the mask technique used in style.css only works with
# monochrome icon sets. Colourful sets (logos:*, devicon:*, skill-icons:*)
# would be flattened to a solid silhouette - use <img> for those instead.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/assets/icons"
API="https://api.iconify.design"

# local filename -> "prefix:icon-name"
# Browse names on https://icon-sets.iconify.design/
declare -A ICONS=(
    [crown]="mdi:crown"             # control plane marker
    [server]="lucide:server"        # worker node marker
    [cpu]="lucide:cpu"              # cpu gauge, ram spec line
    [disk]="lucide:hard-drive"      # storage spec line
    [tag]="lucide:tag"              # k3s version spec line
    [thermometer]="lucide:thermometer"
    [clock]="lucide:clock"
    [check]="lucide:circle-check"   # node Ready
    [alert]="lucide:triangle-alert" # node NotReady
    [linux]="simple-icons:linux"    # footer
    [music]="lucide:music"          # footer
    [guitar]="lucide:guitar"        # footer
    [coffee]="lucide:coffee"        # footer
    [winterfell]="lucide:chess-rook"
    [nightswatch]="token-branded:raven"
    [pods]="carbon:kubernetes-pod"
    [worker]="carbon:kubernetes-worker-node"
    [control]="carbon:kubernetes-control-plane-node"
    [kubernetes]="carbon:logo-kubernetes"
)

mkdir -p "$OUT_DIR"

ok=0
failed=0

# sort so the output order is stable between runs
for name in $(printf '%s\n' "${!ICONS[@]}" | sort); do
    id="${ICONS[$name]}"
    prefix="${id%%:*}"
    icon="${id##*:}"
    dest="${OUT_DIR}/${name}.svg"

    # height=none strips width/height so CSS controls the rendered size
    url="${API}/${prefix}/${icon}.svg?height=none"

    if curl -fsSL "$url" -o "$dest"; then
        printf '  \033[32m\u2713\033[0m %-7s %s\n' "$name" "$id"
        ok=$((ok + 1))
    else
        printf '  \033[31m\u2717\033[0m %-7s %s  <- unbekannter Name?\n' "$name" "$id"
        rm -f "$dest"
        failed=$((failed + 1))
    fi
done

printf '\n%d/%d Icons geschrieben nach %s\n' \
    "$ok" "$((ok + failed))" "${OUT_DIR#$REPO_ROOT/}"

if ((failed > 0)); then
    printf 'Fehlgeschlagene Namen auf https://icon-sets.iconify.design/ pruefen.\n' >&2
    exit 1
fi
