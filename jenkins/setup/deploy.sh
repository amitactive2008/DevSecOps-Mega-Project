#!/usr/bin/env bash
# deploy.sh — Deploy Jenkins to the local Kind cluster
#
# Usage:
#   cd <repo-root>
#   ./jenkins/setup/deploy.sh
#
# Prerequisites: kubectl, helm, kind, podman (all in PATH)
# The Kind cluster must already be running (kind create cluster --name vault ...)

set -euo pipefail

NAMESPACE="jenkins"
HELM_RELEASE="jenkins"
REPO_ROOT="$(git rev-parse --show-toplevel)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── 0. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in kubectl helm kind; do
  command -v "$cmd" &>/dev/null || die "'$cmd' not found. Install it and retry."
done
kubectl cluster-info &>/dev/null || die "No reachable Kubernetes cluster. Is your kind cluster running?"
success "Prerequisites OK"

# ── 1. Namespace + RBAC + buildkitd ──────────────────────────────────────────
info "Applying namespace, RBAC, and buildkitd..."
kubectl apply -k "$REPO_ROOT/jenkins/setup"
success "Namespace, RBAC, and buildkitd applied"

# ── 2. Credentials secret ─────────────────────────────────────────────────────
if kubectl get secret jenkins-credentials -n "$NAMESPACE" &>/dev/null; then
  success "jenkins-credentials secret already exists — skipping"
else
  warn "jenkins-credentials secret not found."
  echo ""
  echo "  Jenkins requires DockerHub credentials and an NVD API key to run pipelines."
  echo "  Option A (interactive — values stay in memory only):"
  echo ""
  read -r -p "  DockerHub username [amitactive2008]: " DHUSER
  DHUSER="${DHUSER:-amitactive2008}"
  read -r -s -p "  DockerHub access token: " DHPASS; echo
  read -r -s -p "  NVD API key (leave blank to skip OWASP stage): " NVDKEY; echo
  echo ""
  kubectl create secret generic jenkins-credentials \
    --from-literal=DOCKERHUB_USERNAME="$DHUSER" \
    --from-literal=DOCKERHUB_PASSWORD="$DHPASS" \
    --from-literal=NVD_API_KEY="${NVDKEY:-placeholder}" \
    -n "$NAMESPACE"
  success "jenkins-credentials secret created"
  echo ""
  echo "  Option B (from template file — do NOT commit credentials.yaml to Git):"
  echo "    cp jenkins/setup/credentials-template.yaml jenkins/setup/credentials.yaml"
  echo "    # Edit credentials.yaml with real values"
  echo "    kubectl apply -f jenkins/setup/credentials.yaml"
fi

# ── 3. Pre-load Jenkins image into Kind node (avoids DockerHub TLS issues) ───
info "Pre-loading Jenkins image into Kind node..."
JENKINS_IMAGE="docker.io/jenkins/jenkins:2.504.1-lts"
KIND_CLUSTER=$(kubectl config current-context | sed 's/kind-//')

if command -v podman &>/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  if ! podman image exists "$JENKINS_IMAGE" 2>/dev/null; then
    info "Pulling $JENKINS_IMAGE with Podman..."
    podman pull "$JENKINS_IMAGE" || warn "Pull failed — kind node will try DockerHub directly"
  fi
  if podman image exists "$JENKINS_IMAGE" 2>/dev/null; then
    TMP_TAR=$(mktemp /tmp/jenkins-XXXXXX.tar)
    podman save -o "$TMP_TAR" "$JENKINS_IMAGE"
    kind load image-archive "$TMP_TAR" --name "$KIND_CLUSTER" 2>/dev/null && \
      success "Jenkins image loaded into kind node" || warn "kind load failed — will pull on demand"
    rm -f "$TMP_TAR"
  fi
else
  warn "Podman not available — Kind node will pull Jenkins image directly from DockerHub"
fi

# ── 4. Add Helm repos ─────────────────────────────────────────────────────────
info "Adding Helm repos..."
helm repo add jenkins   https://charts.jenkins.io 2>/dev/null || true
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
helm repo update jenkins sonarqube
success "Helm repos ready"

# ── 5. Deploy SonarQube ───────────────────────────────────────────────────────
info "Deploying SonarQube (Community edition)..."
kubectl create namespace sonarqube 2>/dev/null || true
helm upgrade --install sonarqube sonarqube/sonarqube \
  --namespace sonarqube \
  --values "$REPO_ROOT/jenkins/setup/sonarqube-values.yaml" \
  --wait \
  --timeout 5m
success "SonarQube deployed"

# ── 6. Generate SonarQube tokens and configure webhook ───────────────────────
info "Setting up SonarQube token for Jenkins..."

if kubectl get secret sonarqube-token -n "$NAMESPACE" &>/dev/null; then
  success "sonarqube-token secret already exists — skipping token generation"
else
  # Port-forward SonarQube to a local port temporarily
  LOCAL_SQ_PORT=19000
  kubectl port-forward svc/sonarqube-sonarqube -n sonarqube \
    "${LOCAL_SQ_PORT}:9000" &>/dev/null &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null' EXIT

  # Wait for SonarQube API to be UP (admin:admin works at install before first login)
  info "Waiting for SonarQube API..."
  for i in $(seq 1 18); do
    SQ_STATUS=$(curl -sf "http://localhost:${LOCAL_SQ_PORT}/api/system/status" \
      2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    [ "$SQ_STATUS" = "UP" ] && break
    sleep 10
  done

  if [ "$SQ_STATUS" != "UP" ]; then
    warn "SonarQube API did not become UP in time — create tokens manually."
  else
    # Step A: Generate a USER_TOKEN for admin (has full API access including webhooks).
    # NOTE: SonarQube 25+ requires token auth for admin APIs; basic auth password
    # still works for token generation right after install (before password change).
    ADMIN_TOKEN=$(curl -s -u admin:admin \
      -X POST "http://localhost:${LOCAL_SQ_PORT}/api/user_tokens/generate" \
      -d "name=deploy-admin&type=USER_TOKEN" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")

    # Step B: Generate a GLOBAL_ANALYSIS_TOKEN for Jenkins scanner
    SQ_TOKEN=$(curl -s -u admin:admin \
      -X POST "http://localhost:${LOCAL_SQ_PORT}/api/user_tokens/generate" \
      -d "name=jenkins-scanner&type=GLOBAL_ANALYSIS_TOKEN" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")

    kill $PF_PID 2>/dev/null
    trap - EXIT

    if [ -n "$SQ_TOKEN" ]; then
      kubectl create secret generic sonarqube-token \
        --from-literal=token="$SQ_TOKEN" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
      success "sonarqube-token (GLOBAL_ANALYSIS_TOKEN) created in namespace $NAMESPACE"
    else
      warn "Analysis token generation failed — create manually in SonarQube UI"
      warn "  My Account → Security → Generate Token (GLOBAL_ANALYSIS_TOKEN)"
      warn "  kubectl create secret generic sonarqube-token --from-literal=token=<token> -n $NAMESPACE"
    fi

    # Step C: Use admin USER_TOKEN to create the Jenkins webhook
    if [ -n "$ADMIN_TOKEN" ]; then
      LOCAL_SQ_PORT2=19001
      kubectl port-forward svc/sonarqube-sonarqube -n sonarqube \
        "${LOCAL_SQ_PORT2}:9000" &>/dev/null &
      PF2=$!
      sleep 3
      WH_RESULT=$(curl -s -w "%{http_code}" -o /dev/null \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -X POST "http://localhost:${LOCAL_SQ_PORT2}/api/webhooks/create" \
        -d "name=jenkins&url=http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/" 2>/dev/null)
      kill $PF2 2>/dev/null
      if [ "$WH_RESULT" = "200" ]; then
        success "SonarQube webhook configured → Jenkins"
      else
        warn "Webhook creation returned HTTP $WH_RESULT — create it manually:"
        warn "  https://sonarqube.kind.local/admin/webhooks → Create"
        warn "  Name: jenkins"
        warn "  URL:  http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/"
      fi
    else
      warn "Could not create webhook automatically (admin token unavailable)"
      warn "Create it manually in SonarQube UI:"
      warn "  https://sonarqube.kind.local/admin/webhooks → Create"
      warn "  Name: jenkins"
      warn "  URL:  http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/"
    fi
  fi
fi

# ── 7. Add sonarqube.kind.local to /etc/hosts (if missing) ───────────────────
if ! grep -q "sonarqube.kind.local" /etc/hosts 2>/dev/null; then
  warn "Add this line to /etc/hosts to access SonarQube UI:"
  warn "  127.0.0.1 sonarqube.kind.local"
  echo ""
  if [[ $EUID -eq 0 ]]; then
    echo "127.0.0.1 sonarqube.kind.local" >> /etc/hosts
    success "Added sonarqube.kind.local to /etc/hosts"
  else
    echo "  Run: echo '127.0.0.1 sonarqube.kind.local' | sudo tee -a /etc/hosts"
  fi
fi

# ── 8. Deploy Jenkins ─────────────────────────────────────────────────────────
info "Deploying Jenkins via Helm (this takes 3-5 minutes)..."
helm upgrade --install "$HELM_RELEASE" jenkins/jenkins \
  --namespace "$NAMESPACE" \
  --values "$REPO_ROOT/jenkins/setup/jenkins-values.yaml" \
  --wait \
  --timeout 10m
success "Jenkins deployed"

# ── 6. /etc/hosts entry ───────────────────────────────────────────────────────
if grep -q "jenkins.kind.local" /etc/hosts 2>/dev/null; then
  success "jenkins.kind.local already in /etc/hosts"
else
  info "Adding jenkins.kind.local to /etc/hosts..."
  echo "127.0.0.1 jenkins.kind.local" | sudo tee -a /etc/hosts
  success "jenkins.kind.local → 127.0.0.1 added to /etc/hosts"
fi

# ── 7. Print access info ──────────────────────────────────────────────────────
ADMIN_PASS=$(kubectl get secret jenkins -n "$NAMESPACE" \
  -o jsonpath='{.data.jenkins-admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Jenkins is ready!                         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  URL:       ${CYAN}https://jenkins.kind.local${NC}"
echo -e "  Username:  admin"
echo -e "  Password:  ${YELLOW}${ADMIN_PASS}${NC}"
echo ""
echo "  Jobs pre-configured:"
echo "    • api-ci    → runs api/Jenkinsfile"
echo "    • client-ci → runs client/Jenkinsfile"
echo ""
echo -e "${YELLOW}  Note: Accept the self-signed cert warning in your browser.${NC}"
echo -e "${YELLOW}  Let's Encrypt cannot issue certs for .local TLD.${NC}"
echo ""
echo "  To watch Jenkins start:"
echo "    kubectl logs -f \$(kubectl get pod -l app.kubernetes.io/component=jenkins-controller"
echo "      -n jenkins -o jsonpath='{.items[0].metadata.name}') -n jenkins"
