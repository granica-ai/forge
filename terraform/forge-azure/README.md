# Forge on Azure (AKS + ADLS Gen2 + Workload Identity)

Deploy Granica Forge on Azure. Mirrors the AWS module (`terraform/forge-aws/`) with Azure-native equivalents.

## Prerequisites

- Terraform **>= 1.9**
- Azure CLI (`az login`)
- `kubelogin` — required for Helm/kubectl auth via Azure AD
- An active Azure subscription with sufficient vCPU quota (see [Quotas](#quotas) below)

## Quick start

```bash
export FORGE_VERSION=v1.2.3
git clone --depth 1 --branch "${FORGE_VERSION}" https://github.com/granica-ai/forge.git
cd forge/terraform/forge-azure
terraform init
terraform apply -var-file=granica-release-images.tfvars \
  -var="subscription_id=YOUR_SUBSCRIPTION_ID"
```

If Forge should access **storage containers**, pass container names:

```bash
terraform apply -var-file=granica-release-images.tfvars \
  -var="subscription_id=YOUR_SUBSCRIPTION_ID" \
  -var='storage_container_names=["your-data-container"]'
```

After apply, point **kubectl** at the new cluster:

```bash
az aks get-credentials --resource-group forge-forge-rg --name forge
```

## What gets created

| Resource | Purpose | AWS Equivalent |
|----------|---------|----------------|
| Resource Group | All resources scoped here | (account-level) |
| VNet + Subnet + NAT Gateway | Networking (optional, skipped if `vnet_id` set) | VPC + subnets + NAT |
| AKS Cluster | Kubernetes control plane | EKS |
| 4 Node Pools | system, spark-driver, spark-executor (Spot), evaluator | EKS managed node groups |
| Storage Account (ADLS Gen2) | `abfs://` storage for system data | S3 buckets |
| 2 Managed Identities | forge-api + spark-driver | IRSA roles |
| Federated Identity Credentials | K8s SA → Managed Identity trust | OIDC provider trust |
| Storage RBAC (Blob Data Contributor) | Data plane access | S3 IAM policies |
| Spark Operator (Helm) | Manages SparkApplication CRDs | Same |
| kube-prometheus-stack (Helm) | Monitoring + Grafana | Same |
| forge-api (Helm) | Forge control plane | Same |

## Release-provided images (`granica-release-images.tfvars`)

Every release tag includes this file with the three **required** image variables pinned to the matching release. Images are pulled from Granica ECR (`us-west-2`). If your AKS cluster cannot reach ECR, push these images to your ACR and update the URIs.

```bash
cd terraform/forge-azure
terraform init
terraform plan \
  -var-file=granica-release-images.tfvars \
  -var-file=forge-local.tfvars \
  -out=tfplan
terraform apply tfplan
```

## Your variable file (`forge-local.tfvars`)

Create a second file (keep it out of version control if it contains account details):

```hcl
subscription_id = "00000000-0000-0000-0000-000000000000"
region          = "eastus2"
cluster_name    = "forge"
mode            = "customer"

# Optional — grant Workload Identity access to storage containers Forge should use
# storage_container_names = [
#   "your-data-container",
# ]

# Optional: existing VNet instead of creating one
# vnet_id   = "/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/..."
# subnet_id = "/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/..."

# Optional: custom VM sizes (defaults shown)
# vm_size_system         = "Standard_D4s_v5"
# vm_size_spark_driver   = "Standard_D8s_v5"
# vm_size_spark_executor = "Standard_D8s_v5"
```

## Variables reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `subscription_id` | Yes | — | Azure subscription ID |
| `forge_api_image` | Yes | — | forge-api container image URI (set via tfvars) |
| `spark_image` | Yes | — | Spark container image URI (set via tfvars) |
| `crunch_image` | Yes | — | crunch-worker sidecar image URI (set via tfvars) |
| `cluster_name` | No | `forge` | AKS cluster name |
| `region` | No | `eastus2` | Azure region |
| `kubernetes_version` | No | `1.32` | Kubernetes version |
| `mode` | No | `customer` | `customer` (scoped RBAC) or `hosted` (account-level RBAC) |
| `storage_container_names` | No | `[]` | Storage containers for data access RBAC |
| `vnet_id` | No | `""` | Existing VNet ID (creates new if empty) |
| `subnet_id` | No | `""` | Existing subnet ID for AKS nodes |
| `storage_account_name` | No | auto | Must be globally unique, 3-24 lowercase alphanumeric |
| `resource_group_name` | No | auto | Resource group name |
| `vm_size_system` | No | `Standard_D4s_v5` | System node pool VM size |
| `vm_size_spark_driver` | No | `Standard_D8s_v5` | Spark driver node pool VM size |
| `vm_size_spark_executor` | No | `Standard_D8s_v5` | Spark executor (Spot) node pool VM size |
| `tags` | No | `{}` | Tags applied to all resources |
| `enable_yunikorn` | No | `false` | Install Apache YuniKorn batch scheduler |
| `tracing_enabled` | No | `true` | Sets FORGE_TRACING_ENABLED on forge-api |

## Deployment modes

Same as AWS:

- **`customer`** (Mode A): Forge deployed in customer's subscription. RBAC scoped to declared `storage_container_names`.
- **`hosted`** (Mode B): Forge deployed in Granica's subscription. RBAC granted at storage account level — the customer controls access via their own storage account RBAC.

## Identity model (Workload Identity vs IRSA)

| Concept | AWS | Azure |
|---------|-----|-------|
| Pod identity | IRSA | Workload Identity |
| Cloud identity | IAM Role | Managed Identity |
| Trust binding | OIDC provider | Federated Identity Credential |
| SA annotation | `eks.amazonaws.com/role-arn` | `azure.workload.identity/client-id` |
| Extra requirement | — | Pod label: `azure.workload.identity/use: "true"` |

The Terraform module handles all of this automatically — creates the Managed Identities, federated credentials, RBAC role assignments, and annotates/labels the K8s service accounts.

## Node pools

| Pool | VM Size (default) | Priority | Autoscale | Labels |
|------|-------------------|----------|-----------|--------|
| system | Standard_D4s_v5 | Regular | 1-4 | `forge.granica.ai/pool=system` |
| sparkdriver | Standard_D8s_v5 | Regular | 0-4 | `forge.granica.ai/pool=spark-driver` |
| sparkexec | Standard_D8s_v5 | **Spot** | 0-8 | `forge.granica.ai/pool=spark-executor` |
| evaluator | Standard_D8s_v5 | Regular | 0-2 | `forge.granica.ai/pool=evaluator` |

Spot pool uses `eviction_policy = Delete` and `spot_max_price = -1` (pay up to on-demand price) for best availability.

**Note:** No Karpenter on Azure — AKS uses the built-in Cluster Autoscaler. Karpenter for Azure is still in preview.

## Networking

When `vnet_id` is empty (default), the module creates:

- VNet: `10.0.0.0/16`
- AKS subnet: `10.0.0.0/20`
- NAT Gateway with static public IP (predictable egress)
- Azure CNI Overlay: pod IPs from `10.48.0.0/16` (virtual, NATed through node IPs)

## Storage

A single Storage Account with ADLS Gen2 (HNS enabled) is created. Forge system data goes into the `system` container. Customer data containers are passed via `storage_container_names`.

URI format: `abfs://container@account.dfs.core.windows.net/path`

## Quotas

Azure vCPU quotas are **per-VM-family** (default 10 per family). Before deploying, check and request increases:

```bash
az vm list-usage --location eastus2 -o table | grep -i "family"
```

Minimum recommended quotas:

| Quota | Default | Recommended |
|-------|---------|-------------|
| Standard Dv5 Family | 10 | 64 |
| Low Priority (Spot) | 3 | 64 |

Request increases via Azure Portal: Support + Troubleshooting > New support request > Quota.

## Outputs

| Output | Description |
|--------|-------------|
| `forge_api_endpoint` | `rest://<ip>:6066` — use as `spark-submit --master` value |
| `cluster_name` | AKS cluster name |
| `kubeconfig_command` | `az aks get-credentials` command to configure kubectl |
| `storage_account_name` | Storage Account name for `abfs://` URIs |
| `resource_group_name` | Resource group containing all resources |
| `deploy_mode` | `customer` or `hosted` |

## Teardown

See [TEARDOWN.md](TEARDOWN.md).

## Differences from AWS module

| Area | AWS (`forge-aws`) | Azure (`forge-azure`) |
|------|-------------------|----------------------|
| Cluster | EKS (module) | AKS (resource) |
| Networking | VPC module | VNet + subnet resources |
| CSI drivers | EBS CSI addon + IRSA | Built-in (no setup needed) |
| Pod identity | IRSA (annotation only) | Workload Identity (annotation + label) |
| Storage | S3 bucket ARNs | Storage containers + RBAC |
| Node scaling | Karpenter (optional) + MNG | Cluster Autoscaler (built-in) |
| Tracing | X-Ray + ADOT Collector | Azure Monitor (native) |
| LB annotations | AWS NLB | Azure LB |
| SG cleanup | TKT-102 workaround | Not needed |
| CI runner | GitLab OIDC + IAM | Not yet implemented |
