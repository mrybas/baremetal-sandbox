#!/bin/bash
# =============================================================================
# baremetal-sandbox Bootstrap Script
# Installs everything needed on Raspberry Pi for bare-metal provisioning
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_cgroups() {
    log_info "Checking cgroups configuration..."
    
    # Check if cgroup memory is enabled
    if ! grep -q "cgroup_memory=1" /proc/cmdline 2>/dev/null; then
        log_error "cgroup memory is not enabled!"
        log_error ""
        log_error "Add the following to your boot cmdline:"
        log_error "  cgroup_memory=1 cgroup_enable=memory"
        log_error ""
        log_error "On Raspberry Pi, edit:"
        log_error "  /boot/firmware/cmdline.txt  (newer Pi OS)"
        log_error "  or /boot/cmdline.txt        (older Pi OS)"
        log_error ""
        log_error "Then reboot and run this script again."
        exit 1
    fi
    
    log_success "cgroups configured correctly"
}

check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Create it from example: cp config.env.example config.env"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log_success "Configuration loaded"
}

check_architecture() {
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        log_success "Architecture: ARM64"
        K3S_ARCH="arm64"
    elif [[ "$ARCH" == "x86_64" ]]; then
        log_success "Architecture: AMD64"
        K3S_ARCH="amd64"
    else
        log_error "Unsupported architecture: $ARCH"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Install dependencies
# -----------------------------------------------------------------------------

install_dependencies() {
    log_info "Installing system dependencies..."
    
    apt-get update
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        wakeonlan \
        nmap \
        vim \
        htop \
        iptables \
        nftables \
        ca-certificates \
        gnupg \
        lsb-release
    
    # Load required kernel modules for k3s
    log_info "Loading kernel modules..."
    modprobe br_netfilter || true
    modprobe overlay || true
    modprobe nf_conntrack || true
    
    # Ensure modules load on boot
    cat > /etc/modules-load.d/k3s.conf << EOF
br_netfilter
overlay
nf_conntrack
EOF
    
    # Enable IP forwarding
    cat > /etc/sysctl.d/k3s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system
    
    log_success "System dependencies installed"
}

# -----------------------------------------------------------------------------
# Install k3s
# -----------------------------------------------------------------------------

install_k3s() {
    log_info "Installing k3s..."
    
    # Check if already installed
    if command -v k3s &> /dev/null; then
        log_warn "k3s already installed, skipping..."
        return
    fi
    
    # k3s configuration
    mkdir -p /etc/rancher/k3s
    
    cat > /etc/rancher/k3s/config.yaml << EOF
# K3s configuration for Tinkerbell
# Disable built-in components we don't need
disable:
  - traefik
  - servicelb

# Network settings
flannel-backend: host-gw
write-kubeconfig-mode: "0644"
EOF

    # Install k3s
    curl -sfL https://get.k3s.io | sh -s - server \
        --config /etc/rancher/k3s/config.yaml
    
    # Wait for k3s service to be active
    log_info "Waiting for k3s service to start..."
    local timeout=120
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if systemctl is-active --quiet k3s; then
            log_success "k3s service is active"
            break
        fi
        
        # Check if service failed
        if systemctl is-failed --quiet k3s; then
            log_error "k3s service failed to start!"
            log_error "Check: journalctl -xeu k3s.service"
            systemctl status k3s.service --no-pager || true
            exit 1
        fi
        
        log_info "Waiting for k3s service... ($elapsed/$timeout)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    # Wait for kubectl to be ready
    log_info "Waiting for Kubernetes API..."
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get nodes &> /dev/null; then
            log_success "Kubernetes API is ready"
            break
        fi
        log_info "Waiting for API... ($elapsed/$timeout)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if ! kubectl get nodes &> /dev/null; then
        log_error "Timeout waiting for Kubernetes API"
        exit 1
    fi
    
    # Configure kubectl for root user
    mkdir -p /root/.kube
    cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    
    # Set KUBECONFIG for this script and all child processes (helm, etc.)
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    
    # For non-root user (pi)
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
        mkdir -p "$USER_HOME/.kube"
        cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
    fi
    
    log_success "k3s installed and running"
    kubectl get nodes
}

# -----------------------------------------------------------------------------
# Install Helm
# -----------------------------------------------------------------------------

install_helm() {
    log_info "Installing Helm..."
    
    if command -v helm &> /dev/null; then
        log_warn "Helm already installed, skipping..."
        return
    fi
    
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_success "Helm installed"
}

# -----------------------------------------------------------------------------
# Install talosctl
# -----------------------------------------------------------------------------

install_talosctl() {
    log_info "Installing talosctl..."
    
    if command -v talosctl &> /dev/null; then
        log_warn "talosctl already installed, skipping..."
        return
    fi
    
    TALOS_VERSION="${TALOS_VERSION:-v1.12.1}"
    
    curl -sL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${K3S_ARCH}" \
        -o /usr/local/bin/talosctl
    chmod +x /usr/local/bin/talosctl
    
    log_success "talosctl ${TALOS_VERSION} installed"
}

# -----------------------------------------------------------------------------
# Create namespaces and base resources
# -----------------------------------------------------------------------------

setup_namespaces() {
    log_info "Creating namespaces..."
    
    # Wait for API server to be fully ready
    log_info "Waiting for Kubernetes API to be fully ready..."
    local timeout=120
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get namespaces &> /dev/null; then
            # Try to create namespace as a test
            if kubectl create namespace test-api-ready --dry-run=server -o yaml &> /dev/null; then
                log_success "API server is ready"
                break
            fi
        fi
        log_info "Waiting for API server... ($elapsed/$timeout)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    # Create namespaces with retry
    local max_retries=5
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if kubectl create namespace tinkerbell --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null; then
            break
        fi
        retry=$((retry + 1))
        log_warn "Retry $retry/$max_retries for namespace creation..."
        sleep 10
    done
    
    kubectl create namespace provisioning --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Namespaces created"
}

# -----------------------------------------------------------------------------
# Install Tinkerbell
# -----------------------------------------------------------------------------

install_tinkerbell() {
    log_info "Installing Tinkerbell Stack..."
    
    # Ensure KUBECONFIG is set for helm
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    
    # Get pod CIDR for trusted proxies
    TRUSTED_PROXIES=$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' 2>/dev/null | tr ' ' ',' || echo "10.42.0.0/16")
    
    CHART_VERSION="${TINKERBELL_CHART_VERSION:-v0.22.0}"
    
    log_info "Installing Tinkerbell chart version ${CHART_VERSION}..."
    log_info "Public IP: ${MANAGEMENT_IP}"
    log_info "Trusted Proxies: ${TRUSTED_PROXIES}"
    
    # Install Tinkerbell from OCI registry
    helm upgrade --install tinkerbell oci://ghcr.io/tinkerbell/charts/tinkerbell \
        --version "${CHART_VERSION}" \
        --create-namespace \
        --namespace tinkerbell \
        --wait \
        --timeout 10m \
        --set "trustedProxies={${TRUSTED_PROXIES}}" \
        --set "publicIP=${MANAGEMENT_IP}" \
        --set "artifactsFileServer=http://${MANAGEMENT_IP}:8080"
    
    log_success "Tinkerbell Stack ${CHART_VERSION} installed"
}

# -----------------------------------------------------------------------------
# Set up HTTP server for images
# -----------------------------------------------------------------------------

setup_http_server() {
    log_info "Setting up HTTP server for images..."
    
    # Create directory for images
    mkdir -p /var/lib/tinkerbell/images
    
    # Apply manifests (apply specific files, not kustomization)
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/http-server/deployment.yaml"
    
    log_success "HTTP server configured"
}

# -----------------------------------------------------------------------------
# Download Talos image
# -----------------------------------------------------------------------------

download_talos_image() {
    log_info "Downloading Talos Linux image..."
    
    TALOS_VERSION="${TALOS_VERSION:-v1.12.1}"
    IMAGE_DIR="/var/lib/tinkerbell/images"
    # Talos only provides .raw.zst (zstd compression)
    ZST_FILE="${IMAGE_DIR}/talos-${TALOS_VERSION}-amd64.raw.zst"
    RAW_FILE="${IMAGE_DIR}/talos-${TALOS_VERSION}-amd64.raw"
    DOWNLOAD_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.raw.zst"
    
    mkdir -p "$IMAGE_DIR"
    
    # Install zstd if not present (needed for decompression)
    if ! command -v zstd &> /dev/null; then
        log_info "Installing zstd for decompression..."
        apt-get install -y zstd
    fi
    
    # Always check if we need to download/decompress
    local need_decompress=false
    
    # Download compressed image if not exists
    if [[ ! -f "$ZST_FILE" ]]; then
        log_info "Downloading from: $DOWNLOAD_URL"
        log_info "This may take a few minutes (~100MB)..."
        
        # Download with retry and continue support
        local max_retries=3
        local retry=0
        
        while [[ $retry -lt $max_retries ]]; do
            if wget --continue --progress=bar:force:noscroll --timeout=300 \
                "$DOWNLOAD_URL" \
                -O "$ZST_FILE"; then
                log_success "Talos image downloaded: $ZST_FILE"
                need_decompress=true
                break
            fi
            
            retry=$((retry + 1))
            log_warn "Download failed, retry $retry/$max_retries..."
            sleep 5
        done
        
        if [[ ! -f "$ZST_FILE" ]]; then
            log_error "Failed to download Talos image after $max_retries attempts"
            log_error "You can download manually:"
            log_error "  wget $DOWNLOAD_URL -O $ZST_FILE"
            exit 1
        fi
    else
        log_info "Compressed image exists: $ZST_FILE"
    fi
    
    # Check if raw file needs to be created/updated
    if [[ ! -f "$RAW_FILE" ]]; then
        need_decompress=true
    elif [[ "$ZST_FILE" -nt "$RAW_FILE" ]]; then
        log_info "Compressed file is newer, re-decompressing..."
        need_decompress=true
    fi
    
    # Decompress image (image2disk v1.0.0 doesn't support .zst)
    if [[ "$need_decompress" == "true" ]]; then
        log_info "Decompressing Talos image (this may take a minute)..."
        rm -f "$RAW_FILE"  # Remove old file if exists
        if zstd -d "$ZST_FILE" -o "$RAW_FILE"; then
            log_success "Talos image decompressed: $RAW_FILE"
        else
            log_error "Failed to decompress Talos image"
            exit 1
        fi
    else
        log_warn "Talos image already exists (uncompressed), skipping..."
    fi
}

# -----------------------------------------------------------------------------
# Apply Hardware and Template resources
# -----------------------------------------------------------------------------

apply_tinkerbell_resources() {
    log_info "Applying Tinkerbell resources..."
    
    # Generate Hardware resources from config.env
    generate_hardware_resources
    
    # Apply Templates (specific yaml files)
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/templates/talos-install.yaml"
    
    # Apply Hardware (generated yaml files)
    for hw_file in "${SCRIPT_DIR}/infrastructure/hardware/"*.yaml; do
        if [[ -f "$hw_file" && "$(basename "$hw_file")" != "kustomization.yaml" ]]; then
            kubectl apply -f "$hw_file"
        fi
    done
    
    log_success "Tinkerbell resources applied"
}

generate_hardware_resources() {
    log_info "Generating Hardware resources..."
    
    HARDWARE_DIR="${SCRIPT_DIR}/infrastructure/hardware"
    mkdir -p "$HARDWARE_DIR"
    
    # Use NODE_DISK from config, default to /dev/sda
    DISK_DEVICE="${NODE_DISK:-/dev/sda}"
    
    # Get HookOS URL from service (LoadBalancer IP)
    HOOKOS_URL="http://${MANAGEMENT_IP}:7173"
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        cat > "${HARDWARE_DIR}/${NAME}.yaml" << EOF
apiVersion: tinkerbell.org/v1alpha1
kind: Hardware
metadata:
  name: ${NAME}
  namespace: tinkerbell
spec:
  # AgentID must match what the agent reports (MAC address)
  agentID: "${MAC}"
  disks:
    - device: ${DISK_DEVICE}
  metadata:
    facility:
      facility_code: homelab
    instance:
      hostname: ${NAME}
      id: "${NAME}"
      operating_system:
        slug: talos
  interfaces:
    - dhcp:
        arch: x86_64
        hostname: ${NAME}
        mac: "${MAC}"
        ip:
          address: ${IP}
          gateway: ${DHCP_GATEWAY}
          netmask: ${DHCP_NETMASK}
        lease_time: 86400
        name_servers:
          - 8.8.8.8
          - 8.8.4.4
      # Netboot configuration required for Tinkerbell v0.22+
      netboot:
        allowPXE: true
        allowWorkflow: true
        osie:
          baseURL: "${HOOKOS_URL}"
EOF
        log_info "  Created: ${NAME} (${MAC} -> ${IP})"
    done
}

# -----------------------------------------------------------------------------
# Generate Talos configs
# -----------------------------------------------------------------------------

generate_talos_configs() {
    log_info "Generating Talos configs..."
    
    TALOS_DIR="${SCRIPT_DIR}/talos"
    mkdir -p "$TALOS_DIR"
    
    cd "$TALOS_DIR"
    
    # Generate base configs (CNI options are applied at reset.sh time)
    talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
        --output-dir . \
        --force
    
    # Remove HostnameConfig document from base configs
    # This allows setting hostname via --config-patch at apply time
    log_info "Removing HostnameConfig from base configs (hostname will be set at apply time)..."
    for config in controlplane.yaml worker.yaml; do
        if [[ -f "$config" ]]; then
            # Remove the entire HostnameConfig YAML document
            python3 -c "
import sys
content = open('$config').read()
docs = content.split('\n---\n')
filtered = [d for d in docs if 'kind: HostnameConfig' not in d]
with open('$config', 'w') as f:
    f.write('\n---\n'.join(filtered))
" 2>/dev/null || {
                # Fallback: use awk if python not available
                awk '
                    BEGIN { skip=0; buffer="" }
                    /^---$/ { 
                        if (!skip && buffer != "") print buffer
                        buffer="---\n"; skip=0; next 
                    }
                    /kind: HostnameConfig/ { skip=1 }
                    { buffer = buffer $0 "\n" }
                    END { if (!skip && buffer != "") printf "%s", buffer }
                ' "$config" > "${config}.tmp" && mv "${config}.tmp" "$config"
            }
        fi
    done
    
    # Generate per-node configs with static IPs
    log_info "Generating per-node configs with static IPs..."
    
    local cp_count=0
    NODE_INTERFACE="${NODE_INTERFACE:-eno1}"
    
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        
        # Determine node type
        if [[ $cp_count -lt $CONTROLPLANE_COUNT ]]; then
            BASE_CONFIG="controlplane.yaml"
            cp_count=$((cp_count + 1))
        else
            BASE_CONFIG="worker.yaml"
        fi
        
        # Create network patch for this node (hostname applied separately at apply time)
        cat > "${TALOS_DIR}/patch-${NAME}.yaml" << EOF
machine:
  network:
    interfaces:
      - interface: ${NODE_INTERFACE}
        addresses:
          - ${IP}/24
        routes:
          - network: 0.0.0.0/0
            gateway: ${DHCP_GATEWAY}
    nameservers:
      - 8.8.8.8
      - 8.8.4.4
EOF
        
        # Generate node-specific config
        talosctl machineconfig patch "${BASE_CONFIG}" \
            --patch @"${TALOS_DIR}/patch-${NAME}.yaml" \
            --output "${TALOS_DIR}/${NAME}.yaml"
        
        # Remove HostnameConfig from per-node config (in case it was preserved from base)
        python3 -c "
content = open('${TALOS_DIR}/${NAME}.yaml').read()
docs = content.split('\n---\n')
filtered = [d for d in docs if 'kind: HostnameConfig' not in d]
with open('${TALOS_DIR}/${NAME}.yaml', 'w') as f:
    f.write('\n---\n'.join(filtered))
" 2>/dev/null || true
        
        log_info "  Generated: ${NAME}.yaml (${IP})"
    done
    
    # Update talosconfig with all node endpoints
    log_info "Updating talosconfig with node endpoints..."
    ALL_ENDPOINTS=""
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        ALL_ENDPOINTS="${ALL_ENDPOINTS}${ALL_ENDPOINTS:+,}${IP}"
    done
    
    # Set endpoints in talosconfig
    talosctl config endpoint ${ALL_ENDPOINTS//,/ } --talosconfig=talosconfig
    talosctl config node ${CONTROLPLANE_IP} --talosconfig=talosconfig
    
    # Copy talosconfig to standard location
    mkdir -p /root/.talos
    cp talosconfig /root/.talos/config
    
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
        mkdir -p "$USER_HOME/.talos"
        cp talosconfig "$USER_HOME/.talos/config"
        chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.talos"
    fi
    
    log_success "Talos configs generated in $TALOS_DIR"
}

# -----------------------------------------------------------------------------
# Create Kubernetes secrets with Talos configs
# -----------------------------------------------------------------------------

create_talos_secrets() {
    log_info "Creating Kubernetes secrets with Talos configs..."
    
    TALOS_DIR="${SCRIPT_DIR}/talos"
    
    kubectl create secret generic talos-secrets \
        --namespace tinkerbell \
        --from-file=talosconfig="${TALOS_DIR}/talosconfig" \
        --from-file=controlplane.yaml="${TALOS_DIR}/controlplane.yaml" \
        --from-file=worker.yaml="${TALOS_DIR}/worker.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Talos secrets created"
}

# -----------------------------------------------------------------------------
# Apply reset job and RBAC
# -----------------------------------------------------------------------------

setup_reset_job() {
    log_info "Setting up reset job..."
    
    # Generate configmap from config.env values
    local NODE_MACS_LIST=""
    local NODE_IPS_LIST=""
    for node in "${NODES[@]}"; do
        IFS=';' read -r NAME MAC IP <<< "$node"
        NODE_MACS_LIST="${NODE_MACS_LIST}${NODE_MACS_LIST:+,}${MAC}"
        NODE_IPS_LIST="${NODE_IPS_LIST}${NODE_IPS_LIST:+,}${IP}"
    done
    
    cat > "${SCRIPT_DIR}/infrastructure/reset-job/configmap.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: provisioner-config
  namespace: tinkerbell
data:
  MANAGEMENT_IP: "${MANAGEMENT_IP}"
  CONTROLPLANE_IP: "${CONTROLPLANE_IP}"
  CLUSTER_NAME: "${CLUSTER_NAME}"
  TALOS_VERSION: "${TALOS_VERSION}"
  NODE_DISK: "${NODE_DISK}"
  NODE_MACS: "${NODE_MACS_LIST}"
  NODE_IPS: "${NODE_IPS_LIST}"
  WOL_WAIT_TIME: "${WOL_WAIT_TIME}"
  WORKFLOW_TIMEOUT: "${WORKFLOW_TIMEOUT}"
  BOOTSTRAP_TIMEOUT: "${BOOTSTRAP_TIMEOUT}"
EOF
    
    # Apply reset job manifests
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/reset-job/rbac.yaml"
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/reset-job/configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/infrastructure/reset-job/job-template.yaml"
    
    log_success "Reset job configured"
}

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Final check
# -----------------------------------------------------------------------------

final_check() {
    log_info "Final check..."
    
    echo ""
    echo "=========================================="
    echo "  K3s Nodes:"
    echo "=========================================="
    kubectl get nodes
    
    echo ""
    echo "=========================================="
    echo "  Tinkerbell Pods:"
    echo "=========================================="
    kubectl get pods -n tinkerbell
    
    echo ""
    echo "=========================================="
    echo "  Hardware Resources:"
    echo "=========================================="
    kubectl get hardware -n tinkerbell
    
    echo ""
    echo "=========================================="
    echo "  Templates:"
    echo "=========================================="
    kubectl get templates -n tinkerbell
    
    echo ""
    log_success "Bootstrap complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify config.env (MAC addresses, IPs)"
    echo "  2. Run: make reset"
    echo "  3. Or: ./reset.sh"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo ""
    echo "=========================================="
    echo "  baremetal-sandbox Bootstrap"
    echo "=========================================="
    echo ""
    
    check_root
    check_config
    check_architecture
    check_cgroups
    
    install_dependencies
    install_k3s
    install_helm
    install_talosctl
    
    setup_namespaces
    install_tinkerbell
    setup_http_server
    download_talos_image
    
    generate_talos_configs
    create_talos_secrets
    apply_tinkerbell_resources
    setup_reset_job
    
    final_check
}

main "$@"
