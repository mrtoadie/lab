#!/bin/bash
# cleanup-stuck-pv.sh

PV=$1
if [ -z "$PV" ]; then
    echo "Usage: $0 <pv-name>"
    exit 1
fi

echo "[1/4] Status check..."
kubectl get pv $PV

echo "[2/4] Remove finalizers..."
kubectl patch pv $PV -p '{"spec":{"finalizers":null}}' --type=json || true

echo "[3/4] Check for bound pods..."
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' | xargs -I{} kubectl get pod {} -o jsonpath='{.spec.volumes}' 2>/dev/null | grep -q $PV && echo "WARNING: PV still bound!"

echo "[4/4] Force delete..."
kubectl delete pv $PV --grace-period=0 --force 2>/dev/null || true

echo "Done. Check status:"
kubectl get pv $PV
