# baremetal-sandbox

Automated bare-metal Kubernetes provisioning for a home lab using Tinkerbell and Talos Linux.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Raspberry Pi (k3s)                         │
│  ┌───────────────────────────┐  ┌───────────────────────────┐   │
│  │       Tinkerbell          │  │       HTTP Server         │   │
│  │   (PXE/DHCP/Workflows)    │  │     (Talos images)        │   │
│  └───────────────────────────┘  └───────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ PXE Boot + Wake-on-LAN
                              ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
    │  node-1  │  │  node-2  │  │  node-3  │  │  node-4  │
    │ (Talos)  │  │ (Talos)  │  │ (Talos)  │  │ (Talos)  │
    │   CP     │  │  Worker  │  │  Worker  │  │  Worker  │
    └──────────┘  └──────────┘  └──────────┘  └──────────┘
                              │
                              ▼
                     Sandbox K8s Cluster
```

## Quick Start

### 1. Configure

```bash
# Clone the repository
git clone https://github.com/<your-username>/infra.git
cd infra

# Copy and edit configuration
cp config.env.example config.env
nano config.env
```

### 2. Bootstrap Raspberry Pi

```bash
# Install k3s, Tinkerbell, and all dependencies
sudo ./bootstrap.sh
```

### 3. Provision Cluster

```bash
# Default: with Flannel CNI
./reset.sh

# Without CNI (for Cilium, Calico, etc.)
./reset.sh --no-cni

# Without CNI and CoreDNS (bare cluster)
./reset.sh --no-cni --no-coredns
```

### 4. Use the Cluster

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

## Commands

### Make Targets

| Command | Description |
|---------|-------------|
| `make bootstrap` | Install everything on Raspberry Pi |
| `make reset` | Full cluster reset (default with Flannel) |
| `make status` | Show Tinkerbell status and workflows |
| `make shell` | Open debug shell on a Talos node |
| `make kubeconfig` | Get sandbox cluster kubeconfig |
| `make logs` | Show current job logs |
| `make watch` | Watch workflows in real-time |
| `make clean` | Delete workflows and jobs |

### Reset Options

```bash
./reset.sh                      # Default with Flannel CNI
./reset.sh --no-cni             # Without CNI (install your own)
./reset.sh --no-coredns         # Without CoreDNS
./reset.sh --no-cni --no-coredns  # Bare cluster
./reset.sh --job                # Run as Kubernetes Job
```

### Debug Shell

Access Talos nodes directly (since Talos has no SSH):

```bash
# Interactive node selection
make shell

# Specific node
make shell NODE=1
make shell NODE=node-1

# Or directly
./scripts/node-shell.sh node-1
```

Inside the shell:
```bash
# Host filesystem is at /host
chroot /host
# Now you have full access to the Talos system
```

## Project Structure

```
infra/
├── bootstrap.sh           # Install k3s + Tinkerbell on Pi
├── reset.sh               # Provision/reset the cluster
├── cleanup.sh             # Remove everything from Pi
├── config.env             # Your configuration (gitignored)
├── config.env.example     # Configuration template
├── Makefile               # Convenience commands
│
├── infrastructure/        # Kubernetes manifests
│   ├── hardware/          # Node definitions (generated, gitignored)
│   ├── templates/         # Tinkerbell workflow templates
│   │   └── talos-install.yaml
│   ├── http-server/       # Image server deployment
│   │   └── deployment.yaml
│   └── reset-job/         # K8s Job for reset (optional)
│
├── scripts/
│   └── node-shell.sh      # Debug shell for Talos nodes
│
├── talos/                 # Talos configs (generated, gitignored)
│
└── kubeconfig             # Cluster access (generated, gitignored)
```

## Configuration

Key settings in `config.env`:

```bash
# Raspberry Pi
MANAGEMENT_IP="192.168.196.201"

# Nodes (format: NAME;MAC;IP)
NODES=(
    "node-1;aa:bb:cc:dd:ee:01;192.168.196.211"
    "node-2;aa:bb:cc:dd:ee:02;192.168.196.212"
    # ...
)

# How many control plane nodes (first N nodes)
CONTROLPLANE_COUNT=1

# Talos version
TALOS_VERSION="v1.12.1"

# Cluster name
CLUSTER_NAME="homelab"
```

## Requirements

### Raspberry Pi
- Raspberry Pi 4/5 (4GB+ RAM)
- Raspberry Pi OS Lite (64-bit)
- Static IP address
- Same network as nodes

### Nodes (Dell/any x86_64)
- PXE boot enabled (first boot option)
- Wake-on-LAN enabled
- Same VLAN as Raspberry Pi

### Network
- Tinkerbell acts as DHCP server for nodes
- Nodes must be able to PXE boot from Pi

## How It Works

1. **Bootstrap** installs k3s and Tinkerbell on Raspberry Pi
2. **Reset** triggers provisioning:
   - Cleans up old workflows
   - Sends Wake-on-LAN to power on nodes (or resets Talos nodes)
   - Nodes PXE boot into HookOS (Tinkerbell's provisioning OS)
   - Tinkerbell streams Talos image to disk
   - Nodes reboot into Talos
   - Talos configs are applied with hostname
   - Kubernetes is bootstrapped
   - Kubeconfig is saved

## Cleanup

To completely remove everything from the Raspberry Pi:

```bash
sudo ./cleanup.sh --yes
```

This removes:
- k3s
- Helm
- talosctl
- Tinkerbell images
- Generated configs
- Network interfaces

## License

MIT
