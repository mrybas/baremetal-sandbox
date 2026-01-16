#!/bin/bash
# =============================================================================
# baremetal-sandbox - Local Reset Script
# Runs a full cluster reset locally (no git required)
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}========================================${NC}"; }

show_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════╗"
    echo "║    baremetal-sandbox - Cluster Reset      ║"
    echo "╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

check_dependencies() {
    local missing=()
    
    for cmd in kubectl talosctl wakeonlan; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Run bootstrap.sh to install them"
        exit 1
    fi
    
    # Use k3s kubeconfig for interacting with Tinkerbell
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

# -----------------------------------------------------------------------------
# Main steps
# -----------------------------------------------------------------------------

step_cleanup_workflows() {
    log_step "STEP 1: Cleanup old workflows"
    
    log_info "Deleting old workflows..."
    kubectl delete workflows --all -n tinkerbell 2>/dev/null || true
    
    # Delete old reset job if exists
    kubectl delete job cluster-reset -n tinkerbell 2>/dev/null || true
    
    # Re-enable PXE boot on all hardware for fresh provisioning
    log_info "Re-enabling PXE boot on all hardware..."
    HOOKOS_URL="http://${MANAGEMENT_IP}:7173"
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        kubectl patch hardware "$NAME" -n tinkerbell --type=merge \
            -p "{\"spec\":{\"agentID\":\"${MAC}\",\"interfaces\":[{\"dhcp\":{\"arch\":\"x86_64\",\"hostname\":\"${NAME}\",\"mac\":\"${MAC}\",\"ip\":{\"address\":\"${IP}\",\"gateway\":\"${DHCP_GATEWAY}\",\"netmask\":\"${DHCP_NETMASK}\"},\"lease_time\":86400,\"name_servers\":[\"8.8.8.8\",\"8.8.4.4\"]},\"netboot\":{\"allowPXE\":true,\"allowWorkflow\":true,\"osie\":{\"baseURL\":\"${HOOKOS_URL}\"}}}]}}" 2>/dev/null || true
    done
    
    log_success "Cleanup complete"
}

step_boot_nodes() {
    log_step "STEP 2: Boot nodes into HookOS"
    
    # Check if nodes are already in Talos (have API on port 50000)
    local talos_nodes=()
    local offline_nodes=()
    
    log_info "Checking current node state..."
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        if timeout 2 bash -c "echo >/dev/tcp/$IP/50000" 2>/dev/null; then
            talos_nodes+=("$node")
            echo "  $NAME: Talos running"
        elif ping -c1 -W2 "$IP" &>/dev/null; then
            echo "  $NAME: Online (unknown OS)"
            offline_nodes+=("$node")
        else
            offline_nodes+=("$node")
            echo "  $NAME: Offline"
        fi
    done
    
    # If nodes are in Talos - use talosctl reset --reboot
    if [[ ${#talos_nodes[@]} -gt 0 ]]; then
        log_info "Found ${#talos_nodes[@]} nodes in Talos, triggering reset + reboot..."
        
        export TALOSCONFIG="${SCRIPT_DIR}/talos/talosconfig"
        
        # Send reset commands in parallel (no wait for completion - they'll reboot)
        for node in "${talos_nodes[@]}"; do
            IFS=';' read -r NAME MAC IP <<< "$node"
            (
                talosctl reset --endpoints "$IP" --nodes "$IP" --graceful=false --reboot &>/dev/null
            ) &
        done
        
        # Give commands time to start
        sleep 3
        log_success "Reset commands sent to ${#talos_nodes[@]} nodes"
        
        # Monitor nodes going offline then coming back
        log_info "Waiting for nodes to reset..."
        local reset_timeout=60
        local reset_elapsed=0
        
        while [[ $reset_elapsed -lt $reset_timeout ]]; do
            local offline=0
            local status=""
            
            for node in "${talos_nodes[@]}"; do
                IFS=';' read -r NAME MAC IP <<< "$node"
                if ping -c1 -W1 "$IP" &>/dev/null; then
                    status+="●"
                else
                    status+="○"
                    offline=$((offline + 1))
                fi
            done
            
            echo -ne "\r  [$status] $offline/${#talos_nodes[@]} rebooting    "
            
            # All nodes offline = reset in progress
            if [[ $offline -eq ${#talos_nodes[@]} ]]; then
                echo ""
                log_success "All nodes rebooting"
                break
            fi
            
            sleep 2
            reset_elapsed=$((reset_elapsed + 2))
        done
        
        # Kill any remaining background talosctl processes
        pkill -f "talosctl reset" 2>/dev/null || true
    fi
    
    # For offline nodes - send WoL
    if [[ ${#offline_nodes[@]} -gt 0 ]]; then
        log_info "Sending Wake-on-LAN to ${#offline_nodes[@]} offline nodes..."
        for node in "${offline_nodes[@]}"; do
            IFS=';' read -r NAME MAC IP <<< "$node"
            wakeonlan "$MAC" 2>/dev/null || etherwake "$MAC" 2>/dev/null || true
            echo "  WoL: $NAME ($MAC)"
        done
    fi
    
    log_info "Waiting for nodes to boot (will create workflows in next step)..."
    
    # Wait for nodes to come online
    local max_timeout=180
    local elapsed=0
    local min_wait=20
    
    sleep $min_wait
    elapsed=$min_wait
    
    while [[ $elapsed -lt $max_timeout ]]; do
        local online=0
        local status=""
        
        for node in "${NODES[@]}"; do
            IFS=';' read -r NAME MAC IP <<< "$node"
            if ping -c1 -W1 "$IP" &>/dev/null; then
                status+="●"
                online=$((online + 1))
            else
                status+="○"
            fi
        done
        
        echo -ne "\r  [$status] $online/${#NODES[@]} online    "
        
        # Exit when all nodes online
        if [[ $online -eq ${#NODES[@]} ]]; then
            echo ""
            log_success "All nodes online!"
            return 0
        fi
        
        # Exit if at least some nodes online after enough time
        if [[ $online -gt 0 ]] && [[ $elapsed -gt 60 ]]; then
            echo ""
            log_warn "$online/${#NODES[@]} nodes online, proceeding..."
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    echo ""
    log_warn "Timeout waiting for nodes. Make sure they can PXE boot."
}

step_create_workflows() {
    log_step "STEP 3: Create Workflows"
    
    TALOS_DIR="${SCRIPT_DIR}/talos"
    local count=0
    local cp_count=0
    
    # Get disk device and Talos version from config
    DISK_DEVICE="${NODE_DISK:-/dev/sda}"
    TALOS_VER="${TALOS_VERSION:-v1.12.1}"
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        count=$((count + 1))
        
        # Determine node type
        if [[ $cp_count -lt $CONTROLPLANE_COUNT ]]; then
            MACHINE_TYPE="controlplane"
            CONFIG_FILE="${TALOS_DIR}/controlplane.yaml"
            cp_count=$((cp_count + 1))
        else
            MACHINE_TYPE="worker"
            CONFIG_FILE="${TALOS_DIR}/worker.yaml"
        fi
        
        log_info "Creating workflow: $NAME ($MACHINE_TYPE)"
        
        # NOTE: device_1 must be MAC address - this is how the agent identifies itself
        kubectl apply -f - <<EOF
apiVersion: tinkerbell.org/v1alpha1
kind: Workflow
metadata:
  name: provision-${NAME}
  namespace: tinkerbell
spec:
  templateRef: talos-install
  hardwareRef: ${NAME}
  hardwareMap:
    device_1: "${MAC}"
    tinkerbell_ip: "${MANAGEMENT_IP}"
    disk_device: "${DISK_DEVICE}"
    talos_version: "${TALOS_VER}"
EOF
        
        log_success "Workflow created: provision-${NAME}"
    done
}

step_wait_workflows() {
    log_step "STEP 4: Wait for Workflows to complete"
    
    local base_timeout=${WORKFLOW_TIMEOUT:-1800}
    local interval=10
    local elapsed=0
    local expected_count=${#NODES[@]}
    local last_progress=""
    local stall_count=0
    local max_stall=30  # 30 × 10s = 5 min without progress
    
    echo ""
    
    while true; do
        # Get workflow details
        local wf_data
        wf_data=$(kubectl get workflows -n tinkerbell -o jsonpath='{range .items[*]}{.metadata.name}:{.status.state}:{.status.currentAction}{"\n"}{end}' 2>/dev/null || echo "")
        
        local completed=0 failed=0 running=0 pending=0
        local status_line=""
        
        while IFS=: read -r name state action; do
            [[ -z "$name" ]] && continue
            
            # Extract short node name (provision-node-1 -> n1)
            local short_name
            short_name=$(echo "$name" | sed 's/provision-node-/n/')
            
            case "$state" in
                "SUCCESS"|"STATE_SUCCESS")
                    ((completed++)) || true
                    status_line+=" ${short_name}:✓"
                    ;;
                "FAILED"|"STATE_FAILED")
                    ((failed++)) || true
                    status_line+=" ${short_name}:✗"
                    ;;
                "RUNNING"|"STATE_RUNNING")
                    ((running++)) || true
                    # Show action name if available
                    local act_short="${action:-...}"
                    act_short=$(echo "$act_short" | sed 's/stream-talos-image/imaging/' | sed 's/trigger-reboot/reboot/')
                    status_line+=" ${short_name}:${act_short}"
                    ;;
                *)
                    ((pending++)) || true
                    status_line+=" ${short_name}:○"
                    ;;
            esac
        done <<< "$wf_data"
        
        # Build progress bar
        local bar=""
        for ((i=0; i<completed; i++)); do bar+="█"; done
        for ((i=0; i<running; i++)); do bar+="▓"; done
        for ((i=0; i<pending; i++)); do bar+="░"; done
        
        # Print status line (overwrite previous)
        printf "\r  [%s] %d/%d |%s  " "$bar" "$completed" "$expected_count" "$status_line"
        
        # Check for failures
        if [[ $failed -gt 0 ]]; then
            echo ""
            log_error "Some workflows failed!"
            kubectl get workflows -n tinkerbell
            exit 1
        fi
        
        # Check for completion
        if [[ $completed -eq $expected_count ]]; then
            echo ""
            log_success "All workflows completed!"
            return 0
        fi
        
        # Smart timeout: track progress changes
        local current_progress="$completed:$running"
        if [[ "$current_progress" != "$last_progress" ]]; then
            stall_count=0
            last_progress="$current_progress"
        else
            stall_count=$((stall_count + 1))
        fi
        
        if [[ $stall_count -ge $max_stall ]]; then
            echo ""
            log_error "No progress for $((max_stall * interval)) seconds"
            kubectl get workflows -n tinkerbell
            exit 1
        fi
        
        if [[ $elapsed -ge $base_timeout ]]; then
            echo ""
            log_error "Maximum timeout reached"
            kubectl get workflows -n tinkerbell
            exit 1
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
}

step_disable_pxe_and_reboot() {
    log_step "STEP 5: Disable PXE and reboot nodes"
    
    # First, create reboot workflows while agents can still receive them
    log_info "Creating reboot workflow template..."
    kubectl apply -f - <<'EOF'
apiVersion: tinkerbell.org/v1alpha1
kind: Template
metadata:
  name: reboot-only
  namespace: tinkerbell
spec:
  data: |
    version: "0.1"
    name: reboot-only
    global_timeout: 60
    tasks:
      - name: "reboot"
        worker: "{{.device_1}}"
        actions:
          - name: "trigger-reboot"
            image: alpine:3.19
            timeout: 30
            pid: host
            command:
              - sh
              - -c
              - "echo 'Rebooting into Talos...' && sleep 2 && echo b > /proc/sysrq-trigger"
EOF
    
    # Delete provision workflows (they're done)
    log_info "Cleaning up provision workflows..."
    kubectl delete workflows --all -n tinkerbell 2>/dev/null || true
    sleep 2
    
    # Create reboot workflows BEFORE disabling PXE
    log_info "Creating reboot workflows..."
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        kubectl apply -f - <<EOF
apiVersion: tinkerbell.org/v1alpha1
kind: Workflow
metadata:
  name: reboot-${NAME}
  namespace: tinkerbell
spec:
  templateRef: reboot-only
  hardwareRef: ${NAME}
  hardwareMap:
    device_1: "${MAC}"
EOF
        log_info "  Created: reboot-${NAME}"
    done
    
    # Wait for reboot workflows to be picked up and executed
    log_info "Waiting for reboot workflows to execute..."
    sleep 10
    
    # Now disable PXE so on reboot they boot from disk
    log_info "Disabling PXE boot for all nodes..."
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        # Disable PXE so nodes boot from disk on next reboot
        kubectl patch hardware "$NAME" -n tinkerbell --type=merge \
            -p "{\"spec\":{\"interfaces\":[{\"dhcp\":{\"arch\":\"x86_64\",\"hostname\":\"${NAME}\",\"mac\":\"${MAC}\",\"ip\":{\"address\":\"${IP}\",\"gateway\":\"${DHCP_GATEWAY}\",\"netmask\":\"${DHCP_NETMASK}\"},\"lease_time\":86400,\"name_servers\":[\"8.8.8.8\",\"8.8.4.4\"]},\"netboot\":{\"allowPXE\":false,\"allowWorkflow\":false}}]}}"
        
        log_info "  PXE disabled for $NAME"
    done
    
    log_success "PXE disabled for all nodes"
    
    # Wait for reboot workflows to execute (agents should pick them up)
    log_info "Waiting for reboot workflows to execute..."
    sleep 15
    
    # Check if nodes went offline (rebooting)
    local offline_count=0
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        if ! ping -c1 -W2 "$IP" &>/dev/null; then
            log_info "  $NAME - rebooting"
            offline_count=$((offline_count + 1))
        else
            log_warn "  $NAME - still online"
        fi
    done
    
    if [[ $offline_count -eq 0 ]]; then
        log_warn "No nodes appear to be rebooting. You may need to manually power cycle them."
    else
        log_success "$offline_count nodes are rebooting into Talos"
    fi
    
    # Clean up reboot resources
    kubectl delete workflows --all -n tinkerbell 2>/dev/null || true
    kubectl delete template reboot-only -n tinkerbell 2>/dev/null || true
}

step_apply_talos_configs() {
    log_step "STEP 6: Apply Talos configs to nodes"
    
    TALOS_DIR="${SCRIPT_DIR}/talos"
    export TALOSCONFIG="${TALOS_DIR}/talosconfig"
    
    log_info "Waiting for nodes to boot into maintenance mode..."
    
    # Wait for nodes to be reachable (check Talos API port 50000)
    local timeout=180
    local elapsed=0
    local all_ready=false
    
    echo ""
    while [[ $elapsed -lt $timeout ]]; do
        local ready_count=0
        local status=""
        
        for node in "${NODES[@]}"; do
            IFS=';' read -r NAME MAC IP <<< "$node"
            # Quick check - just see if port 50000 is open (Talos API)
            if timeout 2 bash -c "echo >/dev/tcp/$IP/50000" 2>/dev/null; then
                status+="✓"
                ready_count=$((ready_count + 1))
            else
                status+="○"
            fi
        done
        
        echo -ne "\r  [$status] $ready_count/${#NODES[@]} ready    "
        
        if [[ $ready_count -eq ${#NODES[@]} ]]; then
            all_ready=true
            echo ""
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [[ "$all_ready" != "true" ]]; then
        echo ""
        log_warn "Not all nodes ready, will apply configs to available nodes"
    fi
    
    log_success "Applying configs..."
    
    # Now apply configs quickly (nodes are already ready)
    local cp_count=0
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        # Determine config file - try per-node first, fallback to base
        local CONFIG_FILE=""
        if [[ -f "${TALOS_DIR}/${NAME}.yaml" ]]; then
            CONFIG_FILE="${TALOS_DIR}/${NAME}.yaml"
        else
            # Fallback to base config
            if [[ $cp_count -lt $CONTROLPLANE_COUNT ]]; then
                CONFIG_FILE="${TALOS_DIR}/controlplane.yaml"
            else
                CONFIG_FILE="${TALOS_DIR}/worker.yaml"
            fi
        fi
        
        # Track controlplane count
        if [[ $cp_count -lt $CONTROLPLANE_COUNT ]]; then
            cp_count=$((cp_count + 1))
        fi
        
        # Build config patches
        log_info "Applying config to $NAME ($IP)..."
        
        # Start with hostname patch
        local PATCHES='{"machine":{"network":{"hostname":"'"${NAME}"'"}}}'
        
        # Add CNI patch if disabled
        if [[ "${SKIP_CNI}" == "true" ]]; then
            PATCHES='{"machine":{"network":{"hostname":"'"${NAME}"'"}},"cluster":{"network":{"cni":{"name":"none"}}}}'
        fi
        
        # Add CoreDNS patch if disabled  
        if [[ "${SKIP_COREDNS}" == "true" ]]; then
            if [[ "${SKIP_CNI}" == "true" ]]; then
                PATCHES='{"machine":{"network":{"hostname":"'"${NAME}"'"}},"cluster":{"network":{"cni":{"name":"none"}},"coreDNS":{"disabled":true}}}'
            else
                PATCHES='{"machine":{"network":{"hostname":"'"${NAME}"'"}},"cluster":{"coreDNS":{"disabled":true}}}'
            fi
        fi
        
        if talosctl apply-config --insecure --nodes "$IP" --file "$CONFIG_FILE" \
            --config-patch "$PATCHES" 2>&1; then
            log_success "Config applied to $NAME"
        else
            # If per-node config fails, try base config
            log_warn "Per-node config failed, trying base config..."
            if [[ $cp_count -le $CONTROLPLANE_COUNT ]]; then
                CONFIG_FILE="${TALOS_DIR}/controlplane.yaml"
            else
                CONFIG_FILE="${TALOS_DIR}/worker.yaml"
            fi
            talosctl apply-config --insecure --nodes "$IP" --file "$CONFIG_FILE" \
                --config-patch "$PATCHES"
            log_success "Base config applied to $NAME"
        fi
    done
    
    log_success "All configs applied"
}

step_wait_talos() {
    log_step "STEP 7: Wait for Talos to configure"
    
    # Get IP of first controlplane node
    IFS=';' read -r NAME MAC CONTROLPLANE_IP <<< "${NODES[0]}"
    
    log_info "Waiting for Talos to apply configuration..."
    sleep 30
    
    log_info "Checking Talos API availability at $CONTROLPLANE_IP..."
    
    local timeout=300
    local elapsed=0
    
    export TALOSCONFIG="${SCRIPT_DIR}/talos/talosconfig"
    
    # Fix permissions on talosconfig if needed
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$TALOSCONFIG" 2>/dev/null || true
    fi
    
    while [[ $elapsed -lt $timeout ]]; do
        # Use explicit --endpoints to avoid "no request forwarding" error
        if talosctl --endpoints "$CONTROLPLANE_IP" --nodes "$CONTROLPLANE_IP" version &>/dev/null; then
            log_success "Talos API is available!"
            return 0
        fi
        log_info "Waiting for Talos API... ($elapsed/$timeout)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "Timeout waiting for Talos API"
    exit 1
}

step_bootstrap_kubernetes() {
    log_step "STEP 8: Bootstrap Kubernetes"
    
    IFS=';' read -r NAME MAC CONTROLPLANE_IP <<< "${NODES[0]}"
    
    export TALOSCONFIG="${SCRIPT_DIR}/talos/talosconfig"
    
    log_info "Running bootstrap on $CONTROLPLANE_IP..."
    talosctl bootstrap --endpoints "$CONTROLPLANE_IP" --nodes "$CONTROLPLANE_IP" 2>&1 || {
        log_warn "Bootstrap may have already been run"
    }
    
    log_success "Bootstrap started"
}

step_wait_kubernetes() {
    log_step "STEP 9: Wait for Kubernetes API"
    
    IFS=';' read -r NAME MAC CONTROLPLANE_IP <<< "${NODES[0]}"
    
    export TALOSCONFIG="${SCRIPT_DIR}/talos/talosconfig"
    
    local timeout=${BOOTSTRAP_TIMEOUT}
    local elapsed=0
    local kubeconfig_path="${SCRIPT_DIR}/kubeconfig"
    
    while [[ $elapsed -lt $timeout ]]; do
        # Try to get kubeconfig (use explicit endpoints)
        if talosctl kubeconfig "$kubeconfig_path" --endpoints "$CONTROLPLANE_IP" --nodes "$CONTROLPLANE_IP" --force 2>/dev/null; then
            # Fix permissions
            if [[ -n "${SUDO_USER:-}" ]]; then
                chown "$SUDO_USER:$SUDO_USER" "$kubeconfig_path" 2>/dev/null || true
            fi
            
            # Verify it works
            export KUBECONFIG="$kubeconfig_path"
            if kubectl get nodes --request-timeout=5s &>/dev/null; then
                log_success "Kubeconfig retrieved and working!"
                break
            fi
        fi
        log_info "Waiting for Kubernetes API... ($elapsed/$timeout)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [[ ! -f "$kubeconfig_path" ]]; then
        log_error "Failed to retrieve kubeconfig"
        exit 1
    fi
}

step_verify_cluster() {
    log_step "STEP 10: Verify cluster"
    
    # Use Talos kubeconfig for new cluster
    export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
    
    if [[ "${SKIP_CNI}" == "true" ]]; then
        log_warn "CNI disabled - nodes will be NotReady until you install a CNI"
        log_info "Waiting for nodes to register..."
        sleep 30
    else
        log_info "Waiting for all nodes to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=300s || true
    fi
    
    echo ""
    kubectl get nodes -o wide
    echo ""
    
    # Save kubeconfig to k3s secret (switch to k3s kubeconfig for this)
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
        create secret generic sandbox-kubeconfig \
        --from-file=kubeconfig="${SCRIPT_DIR}/kubeconfig" \
        -n tinkerbell \
        --dry-run=client -o yaml | kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
    
    log_success "Kubeconfig saved"
}

show_summary() {
    log_step "DONE!"
    
    echo ""
    echo -e "${GREEN}Cluster successfully deployed!${NC}"
    echo ""
    echo "Kubeconfig saved to:"
    echo "  - Local: ${SCRIPT_DIR}/kubeconfig"
    echo "  - K8s Secret: sandbox-kubeconfig (namespace: tinkerbell)"
    echo ""
    echo "Usage:"
    echo "  export KUBECONFIG=${SCRIPT_DIR}/kubeconfig"
    echo "  kubectl get nodes"
    echo ""
    
    if [[ "${SKIP_CNI}" == "true" ]]; then
        echo -e "${YELLOW}⚠ CNI was disabled. Install a CNI to make nodes Ready:${NC}"
        echo ""
        echo "  # Cilium:"
        echo "  helm install cilium cilium/cilium --namespace kube-system"
        echo ""
        echo "  # Calico:"
        echo "  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"
        echo ""
    fi
    
    echo "Or via make:"
    echo "  make kubeconfig"
    echo ""
}

# -----------------------------------------------------------------------------
# Alternative mode: run as Job in k3s
# -----------------------------------------------------------------------------

run_as_job() {
    log_info "Running reset as Kubernetes Job..."
    
    # Delete old job
    kubectl delete job cluster-reset -n tinkerbell 2>/dev/null || true
    
    # Create new job
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/reset-job/job-template.yaml"
    
    log_info "Job created, following logs..."
    
    # Wait for pod to start
    sleep 5
    
    # Follow logs
    kubectl logs -f job/cluster-reset -n tinkerbell
    
    # Check status
    JOB_STATUS=$(kubectl get job cluster-reset -n tinkerbell -o jsonpath='{.status.succeeded}')
    if [[ "$JOB_STATUS" == "1" ]]; then
        log_success "Reset job completed successfully!"
        
        # Save kubeconfig locally
        kubectl get secret sandbox-kubeconfig -n tinkerbell \
            -o jsonpath='{.data.kubeconfig}' | base64 -d > "${SCRIPT_DIR}/kubeconfig"
        
        show_summary
    else
        log_error "Reset job failed"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --job        Run as Kubernetes Job (recommended)"
    echo "  --local      Run locally on Pi"
    echo "  --no-cni     Skip default CNI (Flannel) - install your own later"
    echo "  --no-coredns Skip CoreDNS - install your own later"
    echo "  --help       Show this help"
    echo ""
    echo "Default: --local (with Flannel CNI and CoreDNS)"
    echo ""
    echo "Examples:"
    echo "  ./reset.sh                    # Default with Flannel"
    echo "  ./reset.sh --no-cni           # Without CNI (for Cilium, Calico)"
    echo "  ./reset.sh --no-cni --no-coredns  # Bare cluster"
}

main() {
    show_banner
    check_config
    check_dependencies
    
    local mode="local"
    SKIP_CNI="false"
    SKIP_COREDNS="false"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --job)
                mode="job"
                shift
                ;;
            --local)
                mode="local"
                shift
                ;;
            --no-cni)
                SKIP_CNI="true"
                shift
                ;;
            --no-coredns)
                SKIP_COREDNS="true"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Export for use in functions
    export SKIP_CNI SKIP_COREDNS
    
    # Show configuration summary
    echo ""
    log_info "Configuration:"
    if [[ "${SKIP_CNI}" == "true" ]]; then
        log_warn "  CNI: DISABLED (install Cilium/Calico/etc. after bootstrap)"
    else
        log_info "  CNI: Flannel (default)"
    fi
    if [[ "${SKIP_COREDNS}" == "true" ]]; then
        log_warn "  CoreDNS: DISABLED"
    else
        log_info "  CoreDNS: Enabled (default)"
    fi
    echo ""
    
    if [[ "$mode" == "job" ]]; then
        run_as_job
    else
        step_cleanup_workflows
        step_boot_nodes
        step_create_workflows
        step_wait_workflows
        step_disable_pxe_and_reboot
        step_apply_talos_configs
        step_wait_talos
        step_bootstrap_kubernetes
        step_wait_kubernetes
        step_verify_cluster
        show_summary
    fi
}

main "$@"
