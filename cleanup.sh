#!/bin/bash
# =============================================================================
# baremetal-sandbox - Full Cleanup Script
# Removes k3s, Tinkerbell, and all artifacts for fresh start
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════╗"
    echo "║   baremetal-sandbox - Full Cleanup        ║"
    echo "╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

cleanup_k3s() {
    log_info "Stopping and removing k3s..."
    
    # Stop k3s service
    systemctl stop k3s 2>/dev/null || true
    systemctl disable k3s 2>/dev/null || true
    
    # Use official uninstall script if available
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        log_info "Running k3s uninstall script..."
        /usr/local/bin/k3s-uninstall.sh || true
    fi
    
    # Manual cleanup if uninstall script didn't exist
    rm -f /usr/local/bin/k3s
    rm -f /usr/local/bin/k3s-killall.sh
    rm -f /usr/local/bin/k3s-uninstall.sh
    rm -rf /etc/rancher/k3s
    rm -rf /var/lib/rancher/k3s
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/cni
    rm -rf /etc/cni
    rm -f /etc/systemd/system/k3s.service
    rm -f /etc/systemd/system/k3s.service.env
    
    # Remove kubeconfig
    rm -rf /root/.kube
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
        rm -rf "$USER_HOME/.kube"
    fi
    
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "k3s removed"
}

cleanup_helm() {
    log_info "Removing Helm..."
    
    rm -f /usr/local/bin/helm
    rm -rf /root/.cache/helm
    rm -rf /root/.config/helm
    
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
        rm -rf "$USER_HOME/.cache/helm"
        rm -rf "$USER_HOME/.config/helm"
    fi
    
    log_success "Helm removed"
}

cleanup_talosctl() {
    log_info "Removing talosctl..."
    
    rm -f /usr/local/bin/talosctl
    rm -rf /root/.talos
    
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")
        rm -rf "$USER_HOME/.talos"
    fi
    
    log_success "talosctl removed"
}

cleanup_tinkerbell_images() {
    log_info "Removing Tinkerbell images..."
    
    rm -rf /var/lib/tinkerbell
    
    log_success "Tinkerbell images removed"
}

cleanup_generated_files() {
    log_info "Removing generated files..."
    
    # Remove generated Talos configs
    rm -rf "${SCRIPT_DIR}/talos"
    
    # Remove generated hardware files
    rm -f "${SCRIPT_DIR}/infrastructure/hardware/node-"*.yaml
    rm -f "${SCRIPT_DIR}/infrastructure/hardware/patch-"*.yaml
    
    # Remove kubeconfig
    rm -f "${SCRIPT_DIR}/kubeconfig"
    
    log_success "Generated files removed"
}

cleanup_network() {
    log_info "Cleaning up network..."
    
    # Remove CNI interfaces
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete kube-bridge 2>/dev/null || true
    
    # Remove iptables rules (k3s cleanup should handle this, but just in case)
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    
    log_success "Network cleaned up"
}

show_summary() {
    echo ""
    log_success "Cleanup complete!"
    echo ""
    echo "The following have been removed:"
    echo "  - k3s (Kubernetes)"
    echo "  - Helm"
    echo "  - talosctl"
    echo "  - Tinkerbell images"
    echo "  - Generated configs"
    echo "  - CNI network interfaces"
    echo ""
    echo "To reinstall, run:"
    echo "  sudo ./bootstrap.sh"
    echo ""
}

main() {
    show_banner
    check_root
    
    echo ""
    log_warn "This will completely remove k3s and all related components!"
    echo ""
    
    # Ask for confirmation unless --yes flag is passed
    if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
        read -p "Are you sure? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    fi
    
    cleanup_k3s
    cleanup_helm
    cleanup_talosctl
    cleanup_tinkerbell_images
    cleanup_generated_files
    cleanup_network
    
    show_summary
}

main "$@"
