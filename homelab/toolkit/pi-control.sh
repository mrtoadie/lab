#!/usr/bin/env bash
# /usr/local/bin/rpi-control.sh

HOSTS=("192.168.178.210" "192.168.178.212" "192.168.178.214")
USER="toadie"

ping_hosts() {
  for host in "${HOSTS[@]}"; do
    if ping -c 1 -W 2 "$host" &>/dev/null; then
      printf "✅ %s is up\n" "$host"
    else
      printf "❌ %s is down\n" "$host"
    fi
  done
}

shutdown_hosts() {
  for host in "${HOSTS[@]}"; do
    if ping -c 1 -W 2 "$host" &>/dev/null; then
      printf "🔌 Shutting down %s...\n" "$host"
      ssh "$USER@$host" "sudo shutdown -h now" 2>/dev/null
    else
      printf "⚠️  %s unreachable, skipping\n" "$host"
    fi
  done
}

case "$1" in
  ping)     ping_hosts ;;
  shutdown) shutdown_hosts ;;
  *)        echo "Usage: $0 {ping|shutdown}"; exit 1 ;;
esac
