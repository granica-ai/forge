# Granica Forge (public)

Versioned Terraform, operator install YAML, and reference Kubernetes/Helm layouts aligned with Granica releases.

**Tags** (e.g. `v0.0.0-alpha-citest1`) are the supported contract. `main` is updated with each release.

## Quick start

Replace `FORGE_VERSION` with the tag you are deploying (same value in both sections). You need **Terraform ≥ 1.9**, **AWS credentials**, the **AWS CLI**, and **kubectl** configured for the target cluster after Terraform finishes.

### 1. AWS (Terraform)

Uses the release **`granica-release-images.tfvars`** only (default **`customer`** mode):

```bash
export FORGE_VERSION=v0.0.0-alpha-citest1
git clone --depth 1 --branch "${FORGE_VERSION}" https://github.com/granica-ai/forge.git
cd forge/terraform/forge-aws
terraform init
terraform apply -var-file=granica-release-images.tfvars
```

If Forge should access **S3 buckets**, pass bucket ARNs (`arn:aws:s3:::name` only; swap `YOUR_BUCKET`):

```bash
terraform apply -var-file=granica-release-images.tfvars \
  -var='s3_bucket_arns=["arn:aws:s3:::YOUR_BUCKET"]'
```

After apply, point **kubectl** at the new cluster (defaults: cluster name `forge`, region `us-west-2`—change if you overrode them):

```bash
aws eks update-kubeconfig --region us-west-2 --name forge
```

### 2. Forge operator

```bash
export FORGE_VERSION=v0.0.0-alpha-citest1
kubectl apply -f "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/operator/install.yaml"
```

## Terraform (AWS)

The repository is laid out so the AWS Terraform module and its referenced assets resolve correctly from the repo root:

| Path in this repo | Purpose |
|-------------------|---------|
| `terraform/forge-aws/` | Main AWS module |
| `terraform/forge-aws/granica-release-images.tfvars` | **Published with each git tag** — pins `forge_api_image`, `crunch_image`, and `spark_image` to the matching release |
| `karpenter/` | Karpenter manifests referenced by the module |
| `k8s/` | Reference Kubernetes YAML manifests |
| `helm/` | Reference Helm chart(s) |

**Prerequisites:** Terraform **≥ 1.9**, AWS credentials with permissions to create/manage the resources in this module, and the `aws` CLI available for EKS auth (`aws eks get-token`). Use a **tagged** checkout (or raw files at that tag) so `granica-release-images.tfvars` matches the release you are deploying.

### Release-provided images (`granica-release-images.tfvars`)

Every release tag includes `terraform/forge-aws/granica-release-images.tfvars` with the three **required** image variables already set (`forge_api_image`, `crunch_image`, `spark_image`) to Granica’s ECR URIs for that tag (same versions as the Forge engine release).

Pass it as the **first** `-var-file`, then add your own file for account-specific settings:

```bash
cd terraform/forge-aws
terraform init
terraform plan \
  -var-file=granica-release-images.tfvars \
  -var-file=forge-local.tfvars \
  -out=tfplan
terraform apply tfplan
```

To fetch only the image file without cloning the repo:

```bash
export FORGE_VERSION=v0.0.0-alpha-citest1   # your release tag
curl -fsSL -o granica-release-images.tfvars \
  "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/terraform/forge-aws/granica-release-images.tfvars"
```

Images are pulled from **Granica ECR** (`us-west-2`); your AWS account must be able to use them per your agreement (e.g. pull-through, replication, or shared registry access).

### Your variable file (`forge-local.tfvars`)

Create a second file (keep it out of version control if it contains account details). Common **optional** settings:

| Variable | When |
|----------|------|
| `s3_bucket_arns` | **Optional.** Set when Forge should read/write **S3** in **`customer`** mode: list **bucket** ARNs only (`arn:aws:s3:::name`); the module adds object ARNs for forge-api and Spark IRSA roles. |
| `mode` | Default is `customer`; use `hosted` only per your architecture / docs. |

Example `forge-local.tfvars`:

```hcl
region       = "us-west-2"
cluster_name = "forge"
mode         = "customer"

# Optional — grant IRSA access to buckets Forge should use
# s3_bucket_arns = [
#   "arn:aws:s3:::your-data-bucket",
# ]

# Optional: existing VPC instead of creating one
# vpc_id     = "vpc-..."
# subnet_ids = ["subnet-...", "subnet-...", "..."]
```

Other optional inputs: `kubernetes_version`, `public_access_cidrs`, `tags`, `enable_karpenter`, `gitlab_project_path` / `ci_s3_buckets`, etc. See `variables.tf` in `terraform/forge-aws/`.

### Plan and apply

Review the plan before apply; destroys and replacements affect live infrastructure. For a single interactive step:

```bash
terraform apply -var-file=granica-release-images.tfvars -var-file=forge-local.tfvars
```

## Forge operator

Install the controller and bundled CRDs (image tag matches the git tag):

```bash
export FORGE_VERSION=v0.0.0-alpha-citest1   # replace with your tag
kubectl apply -f "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/operator/install.yaml"
```

Split CRDs (optional) live under `operator/crds/`.

The operator image in `install.yaml` matches the release tag; application images match `granica-release-images.tfvars` for the same tag.

## Docs

See Granica customer documentation for full BYOC and support guidance.
