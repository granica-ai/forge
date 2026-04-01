# Forge on Azure (AKS + ADLS Gen2 + Workload Identity)

Deploy Granica Forge on Azure. Creates an AKS cluster with node pools, ADLS Gen2 storage, Managed Identities, and all required Helm releases.

## Prerequisites

- Terraform **>= 1.9**
- Azure CLI (`az login`)
- `kubelogin`
- `kubectl`
- Sufficient vCPU quota (check with `az vm list-usage --location <region> -o table`)

## Quick start

```bash
export FORGE_VERSION=v1.2.7
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

After apply, point **kubectl** at the new cluster (resource group defaults to `forge-<cluster_name>-rg`):

```bash
az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw cluster_name)
```

> **Note:** First apply may fail on Helm releases (auth propagation). Wait 30s and re-apply.

## What gets created

| Resource | Purpose |
|----------|---------|
| Resource Group | All resources scoped here |
| VNet + Subnet + NAT Gateway | Networking (optional, skipped if `vnet_id` set) |
| AKS Cluster | Kubernetes control plane |
| 4 Node Pools | system, spark-driver, spark-executor (Spot), evaluator |
| Storage Account (ADLS Gen2) | `abfss://` storage for system data |
| 2 Managed Identities | forge-api + spark-driver |
| Federated Identity Credentials | K8s SA → Managed Identity trust |
| Storage RBAC (Blob Data Contributor) | Data plane access |
| Spark Operator (Helm) | Manages SparkApplication CRDs |
| kube-prometheus-stack (Helm) | Monitoring + Grafana |
| forge-api (Helm) | Forge control plane |

## Release-provided images (`granica-release-images.tfvars`)

Every release tag includes this file with the three **required** image variables pinned to the matching release.

Pass it as the **first** `-var-file`, then add your own file for account-specific settings:

```bash
cd terraform/forge-azure
terraform init
terraform plan \
  -var-file=granica-release-images.tfvars \
  -var-file=forge-local.tfvars \
  -out=tfplan
terraform apply tfplan
```

Image versions are set automatically by `granica-release-images.tfvars` — you do not need to specify them. To override any image for testing:

```bash
terraform apply -var-file=granica-release-images.tfvars \
  -var="forge_api_image=granicaaz.azurecr.io/forge-api:v0.6.21-alpha" \
  -var="crunch_image=granicaaz.azurecr.io/crunch:v0.6.21-alpha-azure3" \
  -var="spark_image=granicaaz.azurecr.io/crunch:v0.6.21-alpha-spark"
```

## Your variable file (`forge-local.tfvars`)

```hcl
subscription_id = "00000000-0000-0000-0000-000000000000"
region          = "eastus2"
cluster_name    = "forge"
mode            = "customer"

# Optional — grant Workload Identity access to storage containers
# storage_container_names = ["your-data-container"]

# Optional: existing VNet
# vnet_id   = "/subscriptions/.../providers/Microsoft.Network/virtualNetworks/..."
# subnet_id = "/subscriptions/.../providers/Microsoft.Network/virtualNetworks/.../subnets/..."
```

Other optional inputs: `kubernetes_version`, `vm_size_system`, `vm_size_spark_driver`, `vm_size_spark_executor`, `storage_account_name`, `resource_group_name`, `arch`, `tags`, `enable_yunikorn`. See `variables.tf`.

## Running Forge

### 1. Create API key and verify

```bash
kubectl create secret generic forge-api-keys -n forge --from-literal=keys="my-api-key"
kubectl rollout restart deployment forge-api -n forge
sleep 20
kubectl port-forward svc/forge-api 6066:6066 -n forge &
sleep 3
curl -s http://localhost:6066/healthz
# Expected: {"status":"ok"}
```

### 2. Upload data

Forge needs Parquet data in ADLS Gen2. Create a container and upload your files:

```bash
STORAGE=$(terraform output -raw storage_account_name)
RG=$(terraform output -raw resource_group_name)

# Create container
az storage container create --account-name $STORAGE --name mydata --auth-mode login

# Upload Parquet files
az storage blob upload-batch --account-name $STORAGE --destination mydata \
  --source /path/to/parquet/files --auth-mode login --overwrite

# Grant Forge identities access to the new container
STORAGE_ID=$(az storage account show --name $STORAGE --query id -o tsv)
for MI in $(az identity list --resource-group $RG --query "[].principalId" -o tsv); do
  az role assignment create --assignee $MI --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ID/blobServices/default/containers/mydata" -o none
done
```

### 3. Discovery

```bash
curl -s -H "Authorization: Bearer my-api-key" \
  "http://localhost:6066/v1/discover?prefix=abfss://mydata@${STORAGE}.dfs.core.windows.net/"
```

### 4. Crunch (auto-learn)

```bash
curl -s -X POST http://localhost:6066/v1/submissions/create \
  -H "Authorization: Bearer my-api-key" \
  -H "Content-Type: application/json" \
  -d "{
    \"mainClass\": \"com.granica.forge.ForgeOptimizer\",
    \"appResource\": \"local:///opt/spark/jars/crunch-spark-assembly-0.1.0.jar\",
    \"appArgs\": [\"--table-path\", \"abfss://mydata@${STORAGE}.dfs.core.windows.net/my-table/\", \"--auto-learn\"],
    \"sparkProperties\": {\"spark.granica.enabled\": \"true\"}
  }"
```

### 5. Monitor

```bash
SID="driver-XXXXX"  # submissionId from step 4

# Poll status
curl -s "http://localhost:6066/v1/submissions/status/$SID" -H "Authorization: Bearer my-api-key"

# Watch pods
kubectl get pods -n forge -w

# Driver logs
kubectl logs -f -n forge -l spark-role=driver
```

States: `SUBMITTED` → `RUNNING` → `FINISHED` (success) or `FAILED`

### Console UI

```bash
kubectl port-forward svc/forge-api 6066:6066 -n forge &
# Open http://localhost:6066/console/ in browser
```

## Outputs

| Output | Description |
|--------|-------------|
| `forge_api_endpoint` | `rest://<ip>:6066` |
| `cluster_name` | AKS cluster name |
| `kubeconfig_command` | `az aks get-credentials` command |
| `storage_account_name` | Storage Account name for `abfss://` URIs |
| `resource_group_name` | Resource group name |
| `deploy_mode` | `customer` or `hosted` |

## Teardown

See [TEARDOWN.md](TEARDOWN.md).
