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

# ── 4. Add Helm repo ──────────────────────────────────────────────────────────
info "Adding Jenkins Helm repo..."
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update jenkins
success "Helm repo ready"

# ── 5. Deploy Jenkins ─────────────────────────────────────────────────────────
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
