#!/usr/bin/env bash
set -uo pipefail

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

print_header "CLUSTER DNS STATUS"

print_header_second "DESKTOP DNS"
cat /etc/resolv.conf
echo ""

print_header_second "ROUTER DNS PING TEST"
ping -c 1 192.168.178.1 >/dev/null && echo -e "${GREEN}Router accessible" || echo -e "${RED}Router not reachable"
echo ""

print_header_second "INTERNAL DNS (k3s CoreDNS)"
kubectl get pods -n kube-system | grep coredns
echo ""

print_header_second "DNS RESOLUTION TEST"
dig +short google.com
echo ""

print_header_second "DNS RESOLUTION TIME"
time nslookup google.com >/dev/null 2>&1
