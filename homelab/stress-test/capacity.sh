#!/bin/bash
# capacity-dashboard.sh

echo "=========================================="
echo "      CLUSTER CAPACITY OVERVIEW"
echo "=========================================="
echo ""

# Total Nodes
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "Total Nodes: $NODE_COUNT"

# Total Pod Capacity
MAX_PODS_PER_NODE=110
TOTAL_CAP=$((MAX_PODS_PER_NODE * NODE_COUNT))
USED_PODS=$(kubectl get pods --all-namespaces --no-headers | wc -l)
echo "Pod Capacity: $USED_PODS / $TOTAL_CAP ($(echo "scale=2; $USED_PODS * 100 / $TOTAL_CAP" | bc)%)"

echo ""
echo "=== PER-NODE BREAKDOWN ==="
printf "%-15s %-8s %-10s %-10s\n" "Node" "Pods" "CPU" "Memory"
printf "%-15s %-8s %-10s %-10s\n" "----" "----" "---" "------"

for node in $(kubectl get nodes -o name | cut -d'/' -f2); do
    pod_count=$(kubectl get pods --all-namespaces -o wide --no-headers | grep -w "$node" | wc -l)
    cpu_alloc=$(kubectl get $node -o jsonpath='{.status.allocatable.cpu}')
    cpu_used=$(kubectl top node $node 2>/dev/null | awk 'NR==2 {print $2}' | sed 's/m//')
    
    printf "%-15s %-8s %-10s %-10s\n" "$node" "$pod_count/$MAX_PODS_PER_NODE" "${cpu_alloc} cores" "$(kubectl top node $node 2>/dev/null | awk 'NR==2 {print $4}')"
done

echo ""
echo "=== RESOURCE AVAILABILITY ==="
kubectl describe nodes | grep -A 8 "Allocated resources:" | head -40

echo "=========================================="
