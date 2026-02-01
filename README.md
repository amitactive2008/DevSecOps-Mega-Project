# DevSecOps Mega Project

A production-inspired DevSecOps project demonstrating how to deploy and manage a full-stack application on Kubernetes using Kustomize and Argo CD.

The focus of this project is on correct structure, clean separation of concerns, and real-world deployment patterns.

---

## What This Project Covers

* Kubernetes deployments using **Kustomize (base + overlays)**
* GitOps-style delivery with **Argo CD**
* Secure TLS using **cert-manager**
* External database integration via **AWS RDS**
* Database migrations executed through **Kubernetes Jobs**
* Clear separation between application code and infrastructure configuration

---

## Deployment Model

* **Base** defines what the system is
* **Overlays** define how it runs per environment
* **Infra** defines cluster-level prerequisites required by all environments

This approach keeps deployments predictable, reviewable, and scalable.

---

## Prerequisites

- Docker
- kubectl (with Kustomize support)
- A running Kubernetes cluster
- Ingress Controller (Traefik / NGINX)
- cert-manager installed
- A domain name with DNS access (e.g. Cloudflare)
- DNS configured to point the Ingress LoadBalancer to the domain
- Access to an external MySQL database (AWS RDS or equivalent)

> Basic Kubernetes knowledge is assumed.

---

## Configuration & Secrets

* Secrets (DB credentials, JWT secret) are not committed.
* Environment-specific values are provided via ConfigMaps and Secrets.
* External DB connectivity is handled using an ExternalName Service.

---

## Deployment

### Manual (Kustomize)

Deployment must follow this order:

1️⃣ **Infra layer**

```bash
kubectl apply -k infra/
```

2️⃣ **Application layer**

```bash
kubectl apply -k kubernetes/overlays/dev
```

> Ingress resources reference a `ClusterIssuer`, so the infra layer **must exist first**.

### GitOps (Argo CD)

It is recommended to use **separate Argo CD Applications**:

- **Infra Application**
    
    - Path: `kubernetes/infra/`
        
    - Namespace: `cert-manager`
        
- **Application Deployment**
    
    - Path: `kubernetes/overlays/dev`
        
    - Namespace: `dev`

This keeps cluster-level concerns isolated from application deployments.

---

## Project Status

This project is **actively under development**.

### Implemented

* Jenkins CI pipeline with security stages 
* Kubernetes deployment using Kustomize
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
