# Variables
NAMESPACE := gitea
VALUES_FILE := YAML/gitea-values.yaml
REPO_NAME := network-observability-config

# --- TARGETS ---

.PHONY: all deploy deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-infrahub configure-infrahub sync-topology deploy-flux teardown clean status

all: deploy

# The master build command (Now includes sync-topology)
deploy: deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-infrahub configure-infrahub sync-topology deploy-flux
	@echo "\n🚀 Lab deployment completely fully automated!"

# 1. Setup Namespace, Secrets, and Helm
deploy-gitea:
	@echo "\n📦 Creating namespace and admin secret..."
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic gitea-admin-secret \
		--from-literal=username=admin \
		--from-literal=password=password123 \
		-n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@echo "⛵ Deploying Gitea via Helm..."
	helm repo add gitea-charts https://dl.gitea.com/charts/
	helm repo update
	helm upgrade --install gitea gitea-charts/gitea -f $(VALUES_FILE) -n $(NAMESPACE)

# 2. Wait for Pod and Create Repositories via API
bootstrap-repo:
	@echo "\n⏳ Giving Kubernetes a moment to schedule the pod..."
	@sleep 5
	@echo "⏳ Waiting for Gitea pods to become ready..."
	kubectl wait --for=condition=ready pod -l app=gitea -n $(NAMESPACE) --timeout=300s
	@echo "🛠️ Creating repositories in Gitea..."
	@bash -c ' \
		kubectl port-forward svc/gitea-http 3000:3000 -n $(NAMESPACE) > /dev/null 2>&1 & \
		PF_PID=$$! ; \
		echo "   Polling for HTTP 200 OK on port 3000..." ; \
		RETRY=30 ; \
		while [ $$RETRY -gt 0 ]; do \
			STATUS=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/swagger || true) ; \
			if [ "$$STATUS" = "200" ]; then \
				echo "   ✅ Gitea API is actively responding!" ; \
				break ; \
			fi ; \
			sleep 2 ; \
			RETRY=$$((RETRY-1)) ; \
		done ; \
		if [ $$RETRY -eq 0 ]; then \
			echo "   ❌ Timeout waiting for Gitea API." ; \
			kill $$PF_PID 2>/dev/null || true ; \
			exit 1 ; \
		fi ; \
		echo "   Creating $(REPO_NAME)..." ; \
		curl -s -X POST "http://localhost:3000/api/v1/user/repos" -H "accept: application/json" -H "Content-Type: application/json" -u "admin:password123" -d "{\"name\": \"$(REPO_NAME)\", \"description\": \"GitOps repo for gnmic-operator\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}" > /dev/null; \
		echo "   Creating infrahub-sync..." ; \
		curl -s -X POST "http://localhost:3000/api/v1/user/repos" -H "accept: application/json" -H "Content-Type: application/json" -u "admin:password123" -d "{\"name\": \"infrahub-sync\", \"description\": \"Infrahub Schema and Generators\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}" > /dev/null; \
		kill $$PF_PID 2>/dev/null || true \
	'
	@echo "✅ Repositories created!"

# 3. Extract Token and Deploy CI/CD Runner
deploy-runner:
	@echo "\n🔑 Generating Act Runner Token and deploying runner..."
	@bash -c ' \
		GITEA_POD=$$(kubectl get pods -n $(NAMESPACE) -l app=gitea -o jsonpath="{.items[0].metadata.name}"); \
		RUNNER_TOKEN=$$(kubectl exec -n $(NAMESPACE) $$GITEA_POD -- gitea --config /data/gitea/conf/app.ini actions generate-runner-token); \
		cat YAML/gitea-runner.yaml | sed "s/TOKEN_PLACEHOLDER/$$RUNNER_TOKEN/g" | sed "s/NAMESPACE_PLACEHOLDER/$(NAMESPACE)/g" | kubectl apply -f - \
	'
	@echo "🏃 Runner deployed!"

# 4. Install Telemetry Infrastructure (Cert-Manager, gNMIC, Prometheus)
deploy-telemetry-infra:
	@echo "\n📡 Installing Cert-Manager..."
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.4 --namespace cert-manager --create-namespace --set crds.enabled=true
	@echo "🛠️ Installing gNMIC Operator..."
	helm upgrade --install gnmic-operator oci://ghcr.io/gnmic/operator/charts/gnmic-operator --version 0.2.0 --namespace gnmic-operator --create-namespace
	@echo "📊 Installing Prometheus Stack..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace

# 5. Install Infrahub (Source of Truth)
deploy-infrahub:
	@echo "\n🏗️ Installing Infrahub..."
	helm upgrade --install infrahub oci://registry.opsmill.io/opsmill/chart/infrahub --namespace infrahub --create-namespace

# 6. Load Schema into Infrahub
configure-infrahub:
	@echo "\n⏳ Giving Kubernetes a moment to schedule the Infrahub pods..."
	@sleep 10
	@echo "⏳ Waiting for Infrahub APIs to initialize (Neo4j takes a few minutes)..."
	@if ! command -v infrahubctl >/dev/null 2>&1; then \
		echo "❌ ERROR: infrahub-sdk is not installed. Please run 'pip install infrahub-sdk' before deploying." ; \
		exit 1 ; \
	fi
	@echo "   Waiting for infrahub-server pod to become ready..."
	@kubectl wait --for=condition=ready pod -l infrahub/service=server -n infrahub --timeout=600s
	@echo "   Extracting Admin Token and Injecting Topology Models..."
	@bash -c ' \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		export INFRAHUB_API_TOKEN="$$INFRAHUB_TOKEN"; \
		export INFRAHUB_ADDRESS="http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000"; \
		infrahubctl schema load YAML/schema.yml \
	'
	@echo "✅ Infrahub schema loaded!"

# 7. Sync Containerlab Topology to Infrahub
sync-topology:
	@echo "\n🐍 Syncing Containerlab Topology into Infrahub..."
	@if ! python3 -c "import yaml; import infrahub_sdk" >/dev/null 2>&1; then \
		echo "❌ ERROR: Python dependencies missing. Run 'pip install infrahub-sdk pyyaml'." ; \
		exit 1 ; \
	fi
	@bash -c ' \
		INFRAHUB_POD=$$(kubectl get pod -l infrahub/service=server -n infrahub -o jsonpath="{.items[0].metadata.name}"); \
		INFRAHUB_TOKEN=$$(kubectl exec -n infrahub $$INFRAHUB_POD -- printenv INFRAHUB_INITIAL_ADMIN_TOKEN | tr -d "\r"); \
		export INFRAHUB_API_TOKEN="$$INFRAHUB_TOKEN"; \
		export INFRAHUB_ADDRESS="http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000"; \
		python3 sync_topology.py \
	'
	@echo "✅ Topology fully synced to the Source of Truth!"

# 8. Install and Configure Flux GitOps
deploy-flux:
	@if ! command -v flux >/dev/null 2>&1; then \
		echo "❌ ERROR: flux is not installed. Please install it with 'brew install flux' or 'pip install flux' before deploying." ; \
		exit 1 ; \
	fi
	@echo "\n🌀 Installing Flux controllers..."
	flux install
	@echo "🔗 Connecting Flux to local Gitea repository..."
	@cat YAML/flux-system.yaml | sed "s/REPO_NAME_PLACEHOLDER/$(REPO_NAME)/g" | kubectl apply -f -
	@echo "✅ Flux connected!"

# 9. The "Scorched Earth" Cleanup Command
teardown: clean
clean:
	@echo "\n🔥 Tearing down the lab..."
	helm uninstall gitea -n $(NAMESPACE) > /dev/null 2>&1 || true
	kubectl delete namespace $(NAMESPACE) --ignore-not-found=true
	helm uninstall cert-manager -n cert-manager > /dev/null 2>&1 || true
	kubectl delete namespace cert-manager --ignore-not-found=true
	helm uninstall gnmic-operator -n gnmic-operator > /dev/null 2>&1 || true
	kubectl delete namespace gnmic-operator --ignore-not-found=true
	helm uninstall prometheus -n monitoring > /dev/null 2>&1 || true
	kubectl delete namespace monitoring --ignore-not-found=true
	helm uninstall infrahub -n infrahub > /dev/null 2>&1 || true
	kubectl delete namespace infrahub --ignore-not-found=true
	flux uninstall -s || true
	@echo "🗑️ Lab destroyed. Ready for a fresh start!"

# 10. Check Lab Health
status:
	@echo "\n📊 Checking Pods..."
	kubectl get pods -A | grep -E 'gitea|cert-manager|gnmic|monitoring|infrahub'
	@echo "\n📊 Checking Flux Sync Status..."
	flux get kustomizations