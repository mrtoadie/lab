#!/bin/bash

echo "=== DNS Status ==="
echo ""

echo "🖥️  Desktop DNS:"
cat /etc/resolv.conf
echo ""

echo "📡 Router DNS (Ping Test):"
ping -c 1 192.168.178.1 >/dev/null && echo "✅ Router erreichbar" || echo "❌ Router nicht erreichbar"
echo ""

echo "🌐 Intern DNS (k3s CoreDNS):"
kubectl get pods -n kube-system | grep coredns
echo ""

echo "🧪 DNS Auflösung Test:"
dig +short google.com
echo ""

echo "⏱️  DNS Resolution Time:"
time nslookup google.com >/dev/null 2>&1
