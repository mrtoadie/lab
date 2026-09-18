#!/bin/bash
# /tmp/test-dynacat-k3s.sh

echo "=== 1. API Erreichbarkeit vom Host ==="
curl -k -w "\nHTTP Status: %{http_code}\n" https://192.168.178.210:6443/version

echo ""
echo "=== 2. Token laden und API test ==="
if [ -f dynacat.token ]; then
    TOKEN=$(cat ~/kube-dynacat.token)
    curl -k -H "Authorization: Bearer $TOKEN" \
         -w "\nHTTP Status: %{http_code}\n" \
         https://192.168.178.210:6443/api/v1/nodes | jq -r '.items[].metadata.name'
else
    echo "✗ Token Datei nicht gefunden!"
fi

echo ""
echo "=== 3. Dynacat Container Status ==="
docker ps | grep dynacat
docker logs dynacat --tail 50 | grep -E "error|custom-api|401|500|connection"

echo ""
echo "=== 4. Netzwerk vom Container ==="
docker exec dynacat ping -c 2 192.168.178.210 2>/dev/null || echo "Ping nicht im Container verfügbar"
