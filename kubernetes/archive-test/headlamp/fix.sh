#!/bin/bash
set -e

echo "🗑️  Deleting old headlamp namespace..."
kubectl delete ns headlamp --ignore-not-found --force --grace-period=0

sleep 2

echo "📦 Creating new headlamp with in-cluster config..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: headlamp
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp
  namespace: headlamp
  annotations:
    kubernetes.io/enforce-mountable-secrets: "false"
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-cluster-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: ServiceAccount
  name: headlamp
  namespace: headlamp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headlamp
  namespace: headlamp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: headlamp
  template:
    metadata:
      labels:
        app: headlamp
    spec:
      serviceAccountName: headlamp
      automountServiceAccountToken: true
      restartPolicy: Always
      containers:
      - name: headlamp
        image: ghcr.io/headlamp-k8s/headlamp:v0.24.1
        imagePullPolicy: Always
        ports:
        - containerPort: 4466
        env:
        - name: HEADLAMP_IN_CLUSTER
          value: "true"
        - name: HEADLAMP_BASE_URL
          value: "/"
        - name: DISABLE_DYNAMIC_PLUGINS
          value: "true"
        - name: CONFIG_PATH
          value: ""
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "500m"
        securityContext:
          runAsNonRoot: false
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: headlamp
  namespace: headlamp
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 4466
    nodePort: 30443
  selector:
    app: headlamp
EOF

echo "⏳ Waiting for pod to start..."
sleep 5

echo "📊 Checking pod status..."
kubectl get pods -n headlamp

echo "🔍 Checking logs..."
kubectl logs -n headlamp -l app=headlamp --tail=20

echo "✅ Done! Access Headlamp at http://localhost:30443"
echo "   Or port-forward: kubectl port-forward svc/headlamp -n headlamp 8080:80"
