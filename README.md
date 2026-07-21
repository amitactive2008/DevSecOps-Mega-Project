# DevSecOps Mega Project

A production-inspired, end-to-end DevSecOps project that builds, secures, and deploys a full-stack web application on Kubernetes. It covers the complete lifecycle from source code to a running cluster — including CI pipelines with security scanning, GitOps-based delivery, secrets management, TLS, and database migrations.

The project ships two Kustomize overlays:
- **`overlays/dev`** — targets an AWS EKS cluster with RDS, AWS Secrets Manager, and Traefik
- **`overlays/local`** — targets a local Kind cluster with a MySQL pod, HashiCorp Vault, and NGINX Ingress

---

## Table of Contents

- [What This Project Is](#what-this-project-is)
- [Software Components](#software-components)
- [Repository Structure](#repository-structure)
- [Traffic Flow in the Cluster](#traffic-flow-in-the-cluster)
- [Local Deployment on Kind](#local-deployment-on-kind)
- [Production Deployment](#production-deployment)
- [CI/CD Pipeline](#cicd-pipeline)
- [Secrets Architecture](#secrets-architecture)

---

## What This Project Is

A three-tier web application (React → Node.js → MySQL) deployed on Kubernetes with a full DevSecOps pipeline. It demonstrates real-world patterns:

| Concern | Solution |
|---|---|
| Infrastructure as Code | Kustomize (base + overlays) |
| GitOps delivery | Argo CD |
| CI pipeline | Jenkins (pod-based agents on K8s) |
| Secret Scanning | Gitleaks |
| Dependency vulnerabilities | OWASP Dependency-Check |
| Static code analysis | SonarQube |
| Container scanning | Trivy |
| Secrets at runtime | AWS Secrets Manager (prod) / HashiCorp Vault (local) |
| TLS certificates | cert-manager (Let's Encrypt / self-signed) |
| Database migrations | Kubernetes Job (runs on every deploy) |

---

## Software Components

### Application Layer

| Component | Technology | Description |
|---|---|---|
| **Frontend** | React (nginx) | Single-page app. Pages: Login, Register, Dashboard. Proxies `/api/*` to the backend. |
| **Backend API** | Node.js + Express | REST API. Routes: `/api/auth`, `/api/users`. Health probes: `/live`, `/health`. |
| **Database** | MySQL 8 | Stores users. Schema applied via Sequelize migrations. |

### Kubernetes Infrastructure

| Component | Namespace | Purpose |
|---|---|---|
| **NGINX Ingress** | `ingress-nginx` | Routes external HTTP/HTTPS traffic to frontend and API |
| **cert-manager** | `cert-manager` | Issues and renews TLS certificates (Let's Encrypt or self-signed) |
| **External Secrets Operator** | `external-secrets` | Pulls secrets from Vault/AWS SM → creates K8s Secrets |
| **HashiCorp Vault** | `vault` | Secret store for DB credentials and JWT secret (local) |
| **Migration Job** | `local` / `dev` | Runs `sequelize db:migrate` once per deploy, then exits |

### CI/CD Tools

| Tool | Role |
|---|---|
| **Jenkins** | Orchestrates the pipeline; runs as pods inside Kubernetes |
| **Gitleaks** | Scans source code for accidentally committed secrets |
| **OWASP Dependency-Check** | Audits Node.js dependencies for known CVEs |
| **SonarQube** | SAST — static code analysis and quality gate |
| **Trivy** | Scans Docker images for OS and library vulnerabilities |
| **Argo CD** | GitOps controller — syncs cluster state from Git |
| **Kustomize** | Manages environment-specific Kubernetes manifests |

---

## Repository Structure

```
.
├── api/                        # Node.js backend
│   ├── Dockerfile
│   ├── Jenkinsfile             # CI pipeline for the API
│   ├── routes/                 # authRoutes.js, userRoutes.js
│   ├── controllers/            # authController.js, userController.js
│   ├── models/                 # Sequelize models
│   ├── migrations/             # DB schema migrations
│   └── seeders/                # Initial data (admin user)
│
├── client/                     # React frontend
│   ├── Dockerfile              # Multi-stage: build React → serve with nginx
│   ├── Jenkinsfile             # CI pipeline for the frontend
│   ├── default.conf            # nginx config (proxies /api to backend)
│   └── src/
│       ├── pages/              # Login, Register, Dashboard
│       └── context/            # AuthContext (JWT management)
│
├── kubernetes/
│   ├── base/                   # Shared K8s manifests (no env-specific values)
│   │   ├── api-manifests/      # API Deployment + ClusterIP Service
│   │   ├── client-manifests/   # Client Deployment + ClusterIP Service
│   │   ├── mysql-db/           # ConfigMap, ExternalName Service, Migration Job
│   │   ├── aws-sm/             # ServiceAccount + SecretProviderClass (AWS SM)
│   │   └── ingress/            # Ingress resource (path-based routing)
│   │
│   ├── overlays/
│   │   ├── dev/                # EKS overlay: RDS, AWS SM, Traefik, Let's Encrypt
│   │   └── local/              # Kind overlay: MySQL pod, Vault, nginx, self-signed TLS
│   │
│   └── infra/                  # Cluster-level prereqs (cert-manager issuers, ESO stores)
│
└── jenkins/                    # Jenkins agent pod spec
```

---

## Traffic Flow in the Cluster

### Request Path (Browser → Application)

```
User Browser
     │
     │  HTTPS  (port 443)
     ▼
┌─────────────────────────────────────────────────────┐
│              Ingress Controller (nginx)              │
│          cert-manager TLS termination                │
│                  host: app.local                     │
└────────────────┬────────────────────────────────────┘
                 │
        ┌────────┴────────┐
        │  Path routing   │
        │                 │
   path: /api/*      path: /
        │                 │
        ▼                 ▼
  ┌──────────┐      ┌──────────────┐
  │api-service│      │client-service│
  │ port 5000 │      │   port 80    │
  └─────┬─────┘      └──────┬───────┘
        │                   │
        ▼                   ▼
  ┌──────────┐      ┌──────────────┐
  │  API Pod  │      │  Client Pod  │
  │ (Node.js) │      │   (nginx)    │
  └─────┬─────┘      └──────────────┘
        │
        ▼
  ┌───────────┐
  │mysql-db   │  ← ClusterIP Service (local: selects MySQL pod)
  │  Service  │    (dev: ExternalName → AWS RDS endpoint)
  └─────┬─────┘
        │
        ▼
  ┌───────────┐
  │  MySQL    │
  │  Pod/RDS  │
  └───────────┘
```

### Secret Delivery Path (Vault → Pod)

```
HashiCorp Vault
  (secret/app: DB_USER, DB_PASSWORD, JWT_SECRET)
        │
        │  HTTP API (token auth)
        ▼
External Secrets Operator
  (ClusterSecretStore: vault-backend)
        │
        │  creates / refreshes every 1h
        ▼
  K8s Secret: app-secrets  (namespace: local)
        │
        │  envFrom: secretRef
        ▼
  API Pod  +  Migration Job
  (reads DB_USER, DB_PASSWORD, JWT_SECRET as env vars)
```

### TLS Certificate Path

```
cert-manager ClusterIssuer (selfsigned-issuer / letsencrypt)
        │
        │  issues certificate for app.local / your-domain.com
        ▼
  K8s Secret: app-tls-local  (type: kubernetes.io/tls)
        │
        │  referenced by Ingress spec.tls
        ▼
  Ingress Controller  →  terminates TLS for all inbound HTTPS
```

---

## Local Deployment on Kind

### Prerequisites

```bash
brew install kind kubectl helm vault podman
podman machine start
```

### Step 1 — Create the Kind cluster

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name vault --config kubernetes/overlays/local/kind-config.yaml
```

### Step 2 — Install cluster infrastructure

```bash
# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=120s

# External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace --wait

# NGINX Ingress (kind-specific manifest — uses hostPort 80/443)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=90s

# HashiCorp Vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" --wait
```

### Step 3 — Configure Vault

```bash
# Open a shell into Vault
kubectl exec -it vault-0 -n vault -- /bin/sh

# Inside the pod:
export VAULT_TOKEN=root
export VAULT_ADDR=http://127.0.0.1:8200

# Store secrets (must match MySQL credentials in mysql-deployment.yaml)
vault kv put secret/app \
  DB_USERNAME=appuser \
  DB_PASSWORD=apppass123 \
  JWT_SECRET=localjwtsecret12345678

exit
```

### Step 4 — Create the Vault token Secret for ESO

> This is created imperatively to avoid committing secrets to Git.

```bash
kubectl create secret generic vault-token \
  --from-literal=token=<your-vault-root-token> \
  -n external-secrets
```

### Step 5 — Pre-load Docker images (bypasses DockerHub TLS issues in kind)

```bash
podman pull docker.io/amitactive2008/api:latest
podman pull docker.io/amitactive2008/client:latest1

podman save -o /tmp/api.tar    docker.io/amitactive2008/api:latest
podman save -o /tmp/client.tar docker.io/amitactive2008/client:latest1

export KIND_EXPERIMENTAL_PROVIDER=podman
kind load image-archive /tmp/api.tar    --name vault
kind load image-archive /tmp/client.tar --name vault
```

### Step 6 — Configure /etc/hosts

```bash
echo "127.0.0.1 app.local" | sudo tee -a /etc/hosts
```

### Step 7 — Deploy

```bash
# Preview rendered manifests
kubectl kustomize kubernetes/overlays/local

# Apply
kubectl apply -k kubernetes/overlays/local

# Watch pods come up
kubectl get pods -n local -w
```

Expected pod lifecycle:

| Pod | Status | Description |
|---|---|---|
| `mysql-*` | Running | MySQL starts first, waits for readiness probe |
| `database-migration-*` | Completed | Runs schema migrations + seeds admin user |
| `api-deployment-*` | Running | Starts after DB is ready (readiness probe on `/health`) |
| `client-deployment-*` | Running | Starts independently |

### Step 8 — Verify

```bash
# All pods healthy
kubectl get pods -n local

# ESO synced the secret from Vault
kubectl get externalsecret app-secrets -n local

# TLS cert issued
kubectl get certificate -n local

# API responding
kubectl exec -n local \
  $(kubectl get pod -l app.kubernetes.io/name=api -n local -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:5000/health
# Expected: OK

# Login via ingress
curl -sk -X POST https://app.local/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"admin123"}'
# Expected: {"token":"...","user":{...}}
```

Open **https://app.local** in your browser (accept the self-signed cert warning).

Default seeded credentials: `admin@example.com` / `admin123`

### Teardown

```bash
kubectl delete -k kubernetes/overlays/local
kind delete cluster --name vault
```

---

## Production Deployment

### Prerequisites

- AWS EKS cluster
- AWS RDS MySQL instance
- AWS Secrets Manager secret with `DB_USERNAME`, `DB_PASSWORD`, `JWT_SECRET`
- IAM Role with IRSA for the `app-access-sa` ServiceAccount
- A domain with DNS pointing to the cluster LoadBalancer (e.g. Cloudflare)

### Deployment Order

```bash
# 1. Cluster-level infra (cert-manager issuers, ESO SecretStore)
kubectl apply -k kubernetes/infra/

# 2. Application
kubectl apply -k kubernetes/overlays/dev
```

> Infra must be applied first because the Ingress references a `ClusterIssuer`.

### GitOps with Argo CD

```bash
# Infra application
argocd app create infra \
  --repo https://github.com/<you>/DevSecOps-Mega-Project \
  --path kubernetes/infra \
  --dest-namespace cert-manager \
  --dest-server https://kubernetes.default.svc \
  --sync-policy automated

# App deployment
argocd app create devsecops-dev \
  --repo https://github.com/<you>/DevSecOps-Mega-Project \
  --path kubernetes/overlays/dev \
  --dest-namespace dev \
  --dest-server https://kubernetes.default.svc \
  --sync-policy automated
```

---

## CI/CD Pipeline

Each of `api/` and `client/` has its own `Jenkinsfile`. The pipeline stages are:

```
git push
    │
    ▼
Stage 1: Checkout          — pull source from Git
Stage 2: Compilation       — syntax check all .js files
Stage 3: Gitleaks          — scan for leaked secrets
Stage 4: SCA               — OWASP Dependency-Check (CVE audit)
Stage 5: SAST              — SonarQube static analysis
Stage 6: Quality Gate      — fail build if SonarQube gate fails
Stage 7: Docker Build      — build image, tag with Jenkins build number
Stage 8: Trivy Scan        — scan image for OS/library CVEs
Stage 9: Push to Registry  — push to DockerHub
Stage 10: Update Manifests — update image tag in overlays/dev/kustomization.yaml
    │
    ▼
Argo CD detects Git change → syncs cluster → rolling deploy
```

Jenkins agents run as **ephemeral Kubernetes pods** (defined in `jenkins/Jenkins-agent.yaml`), each container providing a specific tool: `nodejs`, `gitleaks`, `dependency-check`, `sonar`, `docker-cli`, `trivy`.

---

## Secrets Architecture

| Environment | Secret Store | Delivery Method | Secret in Pod |
|---|---|---|---|
| **Local** (Kind) | HashiCorp Vault | External Secrets Operator → K8s Secret | `envFrom: secretRef` |
| **Production** (EKS) | AWS Secrets Manager | Secrets Store CSI Driver + IRSA | Files at `/mnt/secrets/` |

### Why two approaches?

The production pattern (CSI driver + IRSA) avoids storing secrets as K8s Secrets at all — secrets are mounted directly as files. The local pattern (ESO → K8s Secret) is simpler to operate without AWS IAM, while still demonstrating a real secret management workflow with Vault.

---

## Local vs Production Comparison

| Concern | Local (Kind) | Production (EKS) |
|---|---|---|
| Cluster | Kind + Podman | AWS EKS |
| Database | MySQL pod (ClusterIP) | AWS RDS (ExternalName Service) |
| Secret store | HashiCorp Vault | AWS Secrets Manager |
| Secret delivery | ESO → K8s Secret (envFrom) | CSI driver → file mount |
| Ingress controller | NGINX (hostPort 80/443) | Traefik (LoadBalancer) |
| TLS | Self-signed (cert-manager) | Let's Encrypt (cert-manager) |
| Domain | `app.local` via /etc/hosts | Real domain via Cloudflare DNS |
| Replicas | 1 | 2 |
| GitOps | Manual apply | Argo CD |
* Argo CD-based GitOps workflow
* TLS with cert-manager
* Database migrations via Kubernetes Job

### Planned

* Terraform for infrastructure provisioning
* Observability stack (metrics & logging)
* Production environment overlay
* CD pipeline automation (GitOps-driven)

---

## 📌 Final Note

This project is designed to reflect how real DevOps teams structure, deploy, and evolve systems in production.

---
