# Forge on AWS (EKS + S3 + IRSA)

Deploy Granica Forge on AWS. Creates an EKS cluster with managed node groups, S3 IRSA roles, and all required Helm releases.

## Prerequisites

- Terraform **>= 1.9**
- AWS credentials with permissions to create EKS, VPC, IAM, and S3 resources
- `aws` CLI available for EKS auth (`aws eks get-token`)
- `kubectl`

## Quick start

```bash
export FORGE_VERSION=v1.2.3
git clone --depth 1 --branch "${FORGE_VERSION}" https://github.com/granica-ai/forge.git
cd forge/terraform/forge-aws
terraform init
terraform apply -var-file=granica-release-images.tfvars
```

If Forge should access **S3 buckets**, pass bucket ARNs (`arn:aws:s3:::name` only):

```bash
terraform apply -var-file=granica-release-images.tfvars \
  -var='s3_bucket_arns=["arn:aws:s3:::YOUR_BUCKET"]'
```

After apply, point **kubectl** at the new cluster:

```bash
aws eks update-kubeconfig --region us-west-2 --name forge
```

## What gets created

| Resource | Purpose |
|----------|---------|
| VPC + subnets + NAT Gateway | Networking (optional, skipped if `vpc_id` set) |
| EKS Cluster | Kubernetes control plane |
| 4 Managed Node Groups | system, spark-driver, spark-executor (Spot), evaluator |
| EBS CSI Driver IRSA | Persistent volume support |
| forge-api IRSA Role | S3 read/write for discovery, history, metrics, system tables |
| spark-driver IRSA Role | S3 read/write for customer data |
| Spark Operator (Helm) | Manages SparkApplication CRDs |
| kube-prometheus-stack (Helm) | Monitoring + Grafana |
| forge-api (Helm) | Forge control plane |
| Karpenter (optional) | Node auto-scaling with NodePools |

## Release-provided images (`granica-release-images.tfvars`)

Every release tag includes this file with the three **required** image variables pinned to Granica ECR URIs for that tag.

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
export FORGE_VERSION=v1.2.3
curl -fsSL -o granica-release-images.tfvars \
  "https://raw.githubusercontent.com/granica-ai/forge/${FORGE_VERSION}/terraform/forge-aws/granica-release-images.tfvars"
```

Images are pulled from **Granica ECR** (`us-west-2`); your AWS account must be able to use them per your agreement (e.g. pull-through, replication, or shared registry access).

## Your variable file (`forge-local.tfvars`)

Create a second file (keep it out of version control if it contains account details):

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

## Variables reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `forge_api_image` | Yes | — | forge-api container image URI (set via tfvars) |
| `spark_image` | Yes | — | Spark container image URI (set via tfvars) |
| `crunch_image` | Yes | — | crunch-worker sidecar image URI (set via tfvars) |
| `cluster_name` | No | `forge` | EKS cluster name |
| `region` | No | `us-west-2` | AWS region |
| `kubernetes_version` | No | `1.35` | Kubernetes version |
| `mode` | No | `customer` | `customer` (scoped IAM) or `hosted` (broad IAM + bucket policies) |
| `s3_bucket_arns` | No | `[]` | S3 bucket ARNs for IRSA role policies |
| `vpc_id` | No | `""` | Existing VPC ID (creates new if empty) |
| `subnet_ids` | No | `[]` | Existing private subnet IDs |
| `public_access_cidrs` | No | `["0.0.0.0/0"]` | CIDRs allowed to reach EKS API |
| `enable_karpenter` | No | `false` | Install Karpenter + apply NodePool manifests |
| `enable_yunikorn` | No | `false` | Install Apache YuniKorn batch scheduler |
| `tracing_enabled` | No | `true` | Add X-Ray permissions to spark-driver IRSA |
| `gitlab_project_path` | No | `""` | GitLab project path for OIDC CI runner role |
| `ci_s3_buckets` | No | `[]` | S3 bucket names for CI runner role |
| `tags` | No | `{}` | Tags applied to all resources |

## Deployment modes

- **`customer`** (Mode A): Forge deployed in customer's AWS account. IRSA policies scoped to declared `s3_bucket_arns`. The customer's IAM boundary controls what buckets are reachable.
- **`hosted`** (Mode B): Forge deployed in Granica's account with cross-account S3 access. IRSA policy grants `s3:*` on `Resource:*` — the customer's S3 bucket policy is the real access gate.

## Node pools

| Node Group | Instance Types | Capacity | Autoscale | Labels |
|------------|---------------|----------|-----------|--------|
| system | m8g.large | ON_DEMAND | 1-4 | `forge.granica.ai/pool=system` |
| spark-driver | m8g.xlarge | ON_DEMAND | 0-4 | `forge.granica.ai/pool=spark-driver` |
| spark-executor | m8g.2xlarge + 4 others (Spot diversity) | SPOT | 0-8 | `forge.granica.ai/pool=spark-executor` |
| evaluator | m8g.2xlarge | ON_DEMAND | 0-2 | `forge.granica.ai/pool=evaluator` |

All use ARM64 Graviton (AL2023).

When `enable_karpenter = true`, spark-driver/executor/evaluator migrate to Karpenter NodePools (see `karpenter/nodepools.yaml`). The system group stays as a managed node group permanently.

## Outputs

| Output | Description |
|--------|-------------|
| `forge_api_endpoint` | `rest://<hostname>:6066` — use as `spark-submit --master` value |
| `cluster_name` | EKS cluster name |
| `kubeconfig_command` | `aws eks update-kubeconfig` command |
| `deploy_mode` | `customer` or `hosted` |

## Teardown

See [TEARDOWN.md](TEARDOWN.md).
