# Granica Forge (public)

Versioned Terraform, operator install YAML, and reference Kubernetes/Helm layouts aligned with Granica releases.

**Tags** (e.g. `v1.2.3`, or pre-releases like `v1.2.0-beta.1`) are the supported contract. `main` is updated with each release.

## Quick start

Replace `FORGE_VERSION` with the tag you are deploying. You need **Terraform >= 1.9** and **kubectl**.

### 1. Infrastructure (Terraform)

| Cloud | Module | Prerequisites | Guide |
|-------|--------|---------------|-------|
| **AWS** | `terraform/forge-aws/` | AWS CLI, credentials | [AWS README](terraform/forge-aws/README.md) |
| **Azure** | `terraform/forge-azure/` | Azure CLI, `kubelogin` | [Azure README](terraform/forge-azure/README.md) |

**AWS:**

```bash
cd forge/terraform/forge-aws
terraform init
terraform apply -var-file=granica-release-images.tfvars
```

**Azure:**

```bash
cd forge/terraform/forge-azure
terraform init
terraform apply -var-file=granica-release-images.tfvars \
  -var="subscription_id=YOUR_SUBSCRIPTION_ID"
```

### 2. Forge operator

```bash
export FORGE_VERSION=v1.2.3
kubectl apply -f "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/operator/install.yaml"
```

## Repository layout

| Path | Purpose |
|------|---------|
| `terraform/forge-aws/` | AWS module (EKS + S3 + IRSA) |
| `terraform/forge-azure/` | Azure module (AKS + ADLS Gen2 + Workload Identity) |
| `terraform/forge-*/granica-release-images.tfvars` | Image pins per release tag |
| `helm/forge-api/` | Helm chart (multi-cloud via `cloud` value) |
| `k8s/` | Reference K8s manifests (CRDs, RBAC, catalog services) |
| `karpenter/` | Karpenter NodePool manifests (AWS only) |
| `operator/` | Forge operator install YAML + CRDs |

## Forge operator

Install the controller and bundled CRDs (image tag matches the git tag):

```bash
export FORGE_VERSION=vX.Y.Z   # replace with your tag
kubectl apply -f "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/operator/install.yaml"
```

Split CRDs (optional) live under `operator/crds/`.

The operator image in `install.yaml` matches the release tag; application images match `granica-release-images.tfvars` for the same tag.

## Docs

See Granica customer documentation for full BYOC and support guidance. Cloud-specific deployment details are in each module's README:

- [AWS deployment guide](terraform/forge-aws/README.md)
- [Azure deployment guide](terraform/forge-azure/README.md)
