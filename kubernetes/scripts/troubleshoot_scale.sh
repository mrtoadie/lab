#!/bin/bash
# k8s-scale-troubleshoot.sh - Speichere und führe aus

NAMESPACE="${1:-testing-linux}"
DEPLOYMENT="${2:-ubuntu-dev}"

echo "=== 📊 CLUSTER STATUS ==="
kubectl top nodes

echo -e "\n=== 📦 DEPLOYMENT STATUS ==="
kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o wide

echo -e "\n=== ⏳ PENDING PODS ==="
kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.reason}{"\n"}{end}'

echo -e "\n=== 🎯 EVENTS (letzte 50) ==="
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -50

echo -e "\n=== 📋 NODE CAPACITY ==="
kubectl describe nodes | grep -E "Name:|Allocatable|Alloctated|Taints:"

echo -e "\n=== 🔒 RESOURCE QUOTA ==="
kubectl describe quota -n $NAMESPACE

echo -e "\n=== 📌 POD DISRUPTION BUDGET ==="
kubectl get pdb -n $NAMESPACE

echo -e "\n=== 💾 PERSISTENT VOLUMES ==="
kubectl get pv,pvc -n $NAMESPACE
