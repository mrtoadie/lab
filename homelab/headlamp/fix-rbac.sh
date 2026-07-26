#!/bin/bash
set -e

echo "🗑️  Cleaning up old RBAC bindings..."
kubectl delete clusterrolebinding headlamp-view 2>/dev/null || true
kubectl delete clusterrolebinding headlamp-admin 2>/dev/null || true

echo "🔐 Creating cluster-admin binding..."
kubectl create clusterrolebinding headlamp-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=headlamp:headlamp

echo "🔄 Restarting deployment..."
kubectl rollout restart deployment/headlamp -n headlamp

echo "⏳ Waiting for pod to be ready..."
kubectl wait --for=condition=available deployment/headlamp -n headlamp --timeout=60s

echo "📊 Checking logs..."
kubectl logs -n headlamp -l app=headlamp --tail=20

echo "✅ Done! Access Headlamp at http://localhost:30443"
echo "   Or: kubectl port-forward svc/headlamp -n headlamp 8080:80"
