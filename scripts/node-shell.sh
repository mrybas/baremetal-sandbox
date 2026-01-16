#!/bin/bash
# Node shell - creates a privileged debug pod on a Talos node
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

KUBECONFIG="${INFRA_DIR}/kubeconfig"
TALOSCONFIG="${INFRA_DIR}/talos/talosconfig"

# Colors
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Try to get kubeconfig if not exists
if [[ ! -f "$KUBECONFIG" ]]; then
    echo -e "${YELLOW}Kubeconfig not found. Trying to get it...${NC}"
    if [[ -f "$TALOSCONFIG" ]]; then
        TALOSCONFIG="$TALOSCONFIG" talosctl kubeconfig "$KUBECONFIG" 2>/dev/null || true
    fi
fi

if [[ ! -f "$KUBECONFIG" ]]; then
    echo -e "${RED}Could not get kubeconfig. Is the Talos cluster running?${NC}"
    exit 1
fi

export KUBECONFIG

# Get available nodes
NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo -e "${RED}No nodes found in cluster${NC}"
    exit 1
fi

# Handle node selection
NODE="${1:-}"

if [[ -z "$NODE" ]]; then
    echo -e "${BLUE}Available nodes:${NC}"
    for i in "${!NODES[@]}"; do
        ROLE=$(kubectl get node "${NODES[$i]}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null && echo " (control-plane)" || echo "")
        echo "  $((i+1)). ${NODES[$i]}${ROLE}"
    done
    echo ""
    read -p "Select node (1-${#NODES[@]}): " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#NODES[@]} ]]; then
        NODE="${NODES[$((selection-1))]}"
    else
        echo -e "${RED}Invalid selection${NC}"
        exit 1
    fi
elif [[ "$NODE" =~ ^[0-9]+$ ]]; then
    # User passed a number
    if [[ "$NODE" -ge 1 ]] && [[ "$NODE" -le ${#NODES[@]} ]]; then
        NODE="${NODES[$((NODE-1))]}"
    else
        echo -e "${RED}Invalid node number. Available: 1-${#NODES[@]}${NC}"
        exit 1
    fi
else
    # Check if the node exists
    if ! kubectl get node "$NODE" &>/dev/null; then
        echo -e "${RED}Node '$NODE' not found${NC}"
        echo -e "${BLUE}Available nodes:${NC}"
        printf '  %s\n' "${NODES[@]}"
        exit 1
    fi
fi

POD_NAME="debug-shell-$(date +%s)"
NAMESPACE="kube-system"

echo -e "${BLUE}Creating debug shell on ${NODE}...${NC}"

# Create the pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  nodeName: ${NODE}
  hostNetwork: true
  hostPID: true
  hostIPC: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: debug
      image: alpine:3.19
      stdin: true
      tty: true
      securityContext:
        privileged: true
      command: ["/bin/sh", "-c", "trap 'exit 0' TERM; echo 'Host filesystem at /host'; echo 'Use: chroot /host for full access'; sleep infinity & wait"]
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
EOF

# Wait for pod to be ready
echo -e "${BLUE}Waiting for pod to start...${NC}"
kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "${NAMESPACE}" --timeout=60s

# Exec into the pod
echo -e "${GREEN}Connected to ${NODE}! Type 'exit' to leave.${NC}"
kubectl exec -it "${POD_NAME}" -n "${NAMESPACE}" -- /bin/sh

# Cleanup
echo -e "${BLUE}Cleaning up...${NC}"
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
echo -e "${GREEN}Done${NC}"
