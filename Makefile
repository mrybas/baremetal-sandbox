# =============================================================================
# baremetal-sandbox Makefile
# =============================================================================

.PHONY: help bootstrap reset reset-job reset-no-cni cleanup status logs kubeconfig wol talos-gen-config clean shell shell-k3s info

# Colors
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m

# Directories
SCRIPT_DIR := $(shell pwd)
TALOS_DIR := $(SCRIPT_DIR)/talos
KUBECONFIG_FILE := $(SCRIPT_DIR)/kubeconfig

# Note: config.env uses bash arrays which Makefile doesn't support
# Variables are loaded by shell scripts directly

help: ## Show this help
	@echo ""
	@echo "$(BLUE)baremetal-sandbox - Bare Metal Kubernetes Provisioning$(NC)"
	@echo ""
	@echo "$(GREEN)Available commands:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""

# =============================================================================
# Main commands
# =============================================================================

bootstrap: ## Install everything on Raspberry Pi (run with sudo)
	@echo "$(BLUE)Running bootstrap...$(NC)"
	@sudo ./bootstrap.sh

reset: ## Full cluster reset (local)
	@echo "$(BLUE)Running reset...$(NC)"
	@./reset.sh --local

reset-job: ## Full cluster reset (as K8s Job)
	@echo "$(BLUE)Running reset as Job...$(NC)"
	@./reset.sh --job

reset-no-cni: ## Reset cluster without CNI (for Cilium/Calico)
	@echo "$(BLUE)Running reset without CNI...$(NC)"
	@./reset.sh --no-cni

cleanup: ## Remove everything from Raspberry Pi (k3s, configs, etc.)
	@echo "$(BLUE)Running full cleanup...$(NC)"
	@sudo ./cleanup.sh

# =============================================================================
# Monitoring
# =============================================================================

status: ## Show provisioning status
	@echo ""
	@echo "$(BLUE)=== K3s Nodes ===$(NC)"
	@kubectl get nodes 2>/dev/null || echo "K3s not running"
	@echo ""
	@echo "$(BLUE)=== Tinkerbell Pods ===$(NC)"
	@kubectl get pods -n tinkerbell 2>/dev/null || echo "Tinkerbell not installed"
	@echo ""
	@echo "$(BLUE)=== Hardware ===$(NC)"
	@kubectl get hardware -n tinkerbell 2>/dev/null || echo "Hardware not configured"
	@echo ""
	@echo "$(BLUE)=== Workflows ===$(NC)"
	@kubectl get workflows -n tinkerbell 2>/dev/null || echo "No active workflows"
	@echo ""
	@echo "$(BLUE)=== Reset Job ===$(NC)"
	@kubectl get jobs -n tinkerbell -l app=cluster-reset 2>/dev/null || echo "No reset jobs"

logs: ## Show current reset job logs
	@kubectl logs -f job/cluster-reset -n tinkerbell 2>/dev/null || echo "No active reset job"

watch: ## Watch workflows in real-time
	@watch -n 5 'kubectl get workflows -n tinkerbell; echo ""; kubectl get jobs -n tinkerbell -l app=cluster-reset'

# =============================================================================
# Kubeconfig
# =============================================================================

kubeconfig: ## Get sandbox cluster kubeconfig
	@if [ -f "$(KUBECONFIG_FILE)" ]; then \
		echo "$(GREEN)Kubeconfig already exists locally: $(KUBECONFIG_FILE)$(NC)"; \
	else \
		echo "$(BLUE)Retrieving kubeconfig from secret...$(NC)"; \
		kubectl get secret sandbox-kubeconfig -n tinkerbell \
			-o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > $(KUBECONFIG_FILE) \
			&& echo "$(GREEN)Saved to: $(KUBECONFIG_FILE)$(NC)" \
			|| echo "$(YELLOW)Kubeconfig not found. Run: make reset$(NC)"; \
	fi
	@echo ""
	@echo "Usage:"
	@echo "  export KUBECONFIG=$(KUBECONFIG_FILE)"
	@echo "  kubectl get nodes"

kubeconfig-show: ## Show kubeconfig (for copying)
	@kubectl get secret sandbox-kubeconfig -n tinkerbell \
		-o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d \
		|| echo "Kubeconfig not found"

# =============================================================================
# Wake-on-LAN
# =============================================================================

wol: ## Send Wake-on-LAN packets (no provisioning)
	@echo "$(BLUE)Sending WoL packets...$(NC)"
	@bash -c 'source config.env && for node in "$${NODES[@]}"; do \
		IFS=";" read -r NAME MAC IP <<< "$$node"; \
		echo "  WoL: $$NAME ($$MAC)"; \
		wakeonlan "$$MAC" 2>/dev/null || etherwake "$$MAC" 2>/dev/null || true; \
	done'
	@echo "$(GREEN)Done$(NC)"

# =============================================================================
# Talos
# =============================================================================

talos-gen-config: ## Regenerate Talos configs
	@echo "$(BLUE)Generating Talos configs...$(NC)"
	@mkdir -p $(TALOS_DIR)
	@cd $(TALOS_DIR) && talosctl gen config "$(CLUSTER_NAME)" "$(CLUSTER_ENDPOINT)" \
		--output-dir . \
		--force
	@echo "$(GREEN)Configs saved to $(TALOS_DIR)$(NC)"
	@echo ""
	@echo "$(YELLOW)Don't forget to update K8s secrets:$(NC)"
	@echo "  make talos-update-secrets"

talos-update-secrets: ## Update Talos secrets in K8s
	@echo "$(BLUE)Updating Talos secrets...$(NC)"
	@kubectl create secret generic talos-secrets \
		--namespace tinkerbell \
		--from-file=talosconfig="$(TALOS_DIR)/talosconfig" \
		--from-file=controlplane.yaml="$(TALOS_DIR)/controlplane.yaml" \
		--from-file=worker.yaml="$(TALOS_DIR)/worker.yaml" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)Secrets updated$(NC)"

talos-status: ## Talos nodes status (requires kubeconfig)
	@TALOSCONFIG=$(TALOS_DIR)/talosconfig talosctl --nodes $(CONTROLPLANE_IP) health || true

# =============================================================================
# Tinkerbell
# =============================================================================

tinkerbell-reinstall: ## Reinstall Tinkerbell
	@echo "$(BLUE)Reinstalling Tinkerbell...$(NC)"
	@helm upgrade --install tinkerbell tinkerbell/stack \
		--namespace tinkerbell \
		--values /tmp/tinkerbell-values.yaml \
		--wait \
		--timeout 10m

hardware-apply: ## Apply Hardware resources
	@kubectl apply -f infrastructure/hardware/

templates-apply: ## Apply Template resources
	@kubectl apply -f infrastructure/templates/

# =============================================================================
# Cleanup
# =============================================================================

clean-workflows: ## Delete all workflows
	@kubectl delete workflows --all -n tinkerbell 2>/dev/null || true
	@echo "$(GREEN)Workflows deleted$(NC)"

clean-jobs: ## Delete all reset jobs
	@kubectl delete jobs -l app=cluster-reset -n tinkerbell 2>/dev/null || true
	@echo "$(GREEN)Jobs deleted$(NC)"

clean-kubeconfig: ## Delete local kubeconfig
	@rm -f $(KUBECONFIG_FILE)
	@echo "$(GREEN)Kubeconfig deleted$(NC)"

clean: clean-workflows clean-jobs clean-kubeconfig ## Full cleanup

# =============================================================================
# Development / Debug
# =============================================================================

shell-k3s: ## Open debug shell in k3s cluster (tinkerbell namespace)
	@kubectl run -it --rm debug --image=alpine:3.19 -n tinkerbell -- /bin/sh

# Node shell - usage: make shell [NODE=1|node-name]
NODE ?=
shell: ## Open privileged shell on Talos node
	@./scripts/node-shell.sh $(NODE)

info: ## Show current configuration
	@echo "$(BLUE)Current configuration:$(NC)"
	@bash -c 'source config.env && \
		echo "Management IP: $$MANAGEMENT_IP"; \
		echo "Cluster: $$CLUSTER_NAME ($$CLUSTER_ENDPOINT)"; \
		echo "Talos: $$TALOS_VERSION"; \
		echo ""; \
		echo "Nodes:"; \
		for node in "$${NODES[@]}"; do \
			IFS=";" read -r NAME MAC IP <<< "$$node"; \
			echo "  $$NAME: $$IP ($$MAC)"; \
		done'
