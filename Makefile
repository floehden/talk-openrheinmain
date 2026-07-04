# Variables
NAMESPACE := gitea
VALUES_FILE := YAML/gitea-values.yaml
REPO_NAME := network-observability-config

# --- YAML DEFINITIONS ---

define RUNNER_YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea-runner
  namespace: $(NAMESPACE)
  labels:
    app: gitea-runner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea-runner
  template:
    metadata:
      labels:
        app: gitea-runner
    spec:
      containers:
      - name: runner
        image: gitea/act_runner:latest
        env:
        - name: GITEA_INSTANCE_URL
          value: "http://gitea-http.gitea.svc.cluster.local:3000"
        - name: GITEA_RUNNER_REGISTRATION_TOKEN
          value: "TOKEN_PLACEHOLDER"
        - name: GITEA_RUNNER_NAME
          value: "k8s-local-runner"
        - name: GITEA_RUNNER_LABELS
          value: "ubuntu-latest"
endef
export RUNNER_YAML

define FLUX_YAML
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: observability-config
  namespace: flux-system
spec:
  interval: 1m
  url: http://gitea-http.gitea.svc.cluster.local:3000/admin/$(REPO_NAME).git
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: observability-sync
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: observability-config
  path: ./
  prune: true
endef
export FLUX_YAML

# --- TARGETS ---

.PHONY: all deploy deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-flux teardown clean status

all: deploy

# The master build command (Updated to include telemetry-infra before flux)
deploy: deploy-gitea bootstrap-repo deploy-runner deploy-telemetry-infra deploy-flux
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

# 2. Wait for Pod and Create Repo via API
bootstrap-repo:
	@echo "\n⏳ Waiting for Gitea pods to become ready (This takes a minute)..."
	kubectl wait --for=condition=ready pod -l app=gitea -n $(NAMESPACE) --timeout=300s
	@echo "🛠️ Creating $(REPO_NAME) repository..."
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
		curl -s -X POST "http://localhost:3000/api/v1/user/repos" \
			-H "accept: application/json" \
			-H "Content-Type: application/json" \
			-u "admin:password123" \
			-d "{\"name\": \"$(REPO_NAME)\", \"description\": \"GitOps repo for gnmic-operator\", \"private\": false, \"auto_init\": true, \"default_branch\": \"main\"}" > /dev/null; \
		kill $$PF_PID 2>/dev/null || true \
	'
	@echo "✅ Repository created!"

# 3. Extract Token and Deploy CI/CD Runner
deploy-runner:
	@echo "\n🔑 Generating Act Runner Token and deploying runner..."
	@bash -c ' \
		GITEA_POD=$$(kubectl get pods -n $(NAMESPACE) -l app=gitea -o jsonpath="{.items[0].metadata.name}"); \
		RUNNER_TOKEN=$$(kubectl exec -n $(NAMESPACE) $$GITEA_POD -- gitea --config /data/gitea/conf/app.ini actions generate-runner-token); \
		echo "$$RUNNER_YAML" | sed "s/TOKEN_PLACEHOLDER/$$RUNNER_TOKEN/g" | kubectl apply -f - \
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

# 5. Install and Configure Flux GitOps
deploy-flux:
	@echo "\n🌀 Installing Flux controllers..."
	flux install
	@echo "🔗 Connecting Flux to local Gitea repository..."
	@echo "$$FLUX_YAML" | kubectl apply -f -
	@echo "✅ Flux connected!"

# 6. The "Scorched Earth" Cleanup Command
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
	flux uninstall -s || true
	@echo "🗑️ Lab destroyed. Ready for a fresh start!"

# 7. Check Lab Health
status:
	@echo "\n📊 Checking Pods..."
	kubectl get pods -A | grep -E 'gitea|cert-manager|gnmic|monitoring'
	@echo "\n📊 Checking Flux Sync Status..."
	flux get kustomizations