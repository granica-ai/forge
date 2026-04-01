# Forge on Azure (AKS + ADLS Gen2 + Workload Identity)

Deploy Granica Forge on Azure and run Crunch. This guide assumes you are running from **Azure Cloud Shell** (`shell.azure.com`), which has `az`, `terraform`, `kubectl`, and `kubelogin` pre-installed.

## Step 1: Clone the repo

```bash
export FORGE_VERSION=v1.2.7
git clone --depth 1 --branch "${FORGE_VERSION}" https://github.com/granica-ai/forge.git
cd forge/terraform/forge-azure
```

## Step 2: Create your config

```bash
cat > forge-local.tfvars <<'EOF'
subscription_id = "YOUR_SUBSCRIPTION_ID"
region          = "eastus2"
cluster_name    = "my-forge"
mode            = "customer"

# VM sizes — adjust to match your quota
# vm_size_system         = "Standard_D2as_v7"
# vm_size_spark_driver   = "Standard_F4as_v7"
# vm_size_spark_executor = "Standard_F4as_v7"
EOF
```

## Step 3: Deploy

```bash
terraform init
terraform apply -var-file=granica-release-images.tfvars -var-file=forge-local.tfvars -auto-approve
```

> First apply may fail on Helm releases (auth propagation delay). Wait 30s and re-apply:
> ```bash
> terraform apply -var-file=granica-release-images.tfvars -var-file=forge-local.tfvars -auto-approve
> ```

## Step 4: Connect to the cluster

```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name $(terraform output -raw cluster_name)
kubectl get pods -A
```

## Step 5: Create API key and verify

```bash
kubectl create secret generic forge-api-keys -n forge --from-literal=keys="my-api-key"
kubectl rollout restart deployment forge-api -n forge
sleep 20
kubectl port-forward svc/forge-api 6066:6066 -n forge &
sleep 3
curl -s http://localhost:6066/healthz
```

Expected: `{"status":"ok"}`

## Step 6: Upload data

```bash
STORAGE=$(terraform output -raw storage_account_name)
RG=$(terraform output -raw resource_group_name)

# Create a container for your data
az storage container create --account-name $STORAGE --name mydata --auth-mode login

# Upload Parquet files
az storage blob upload-batch --account-name $STORAGE --destination mydata \
  --destination-path "my-table" --source /path/to/parquet/files \
  --auth-mode login --overwrite

# Grant Forge identities access
STORAGE_ID=$(az storage account show --name $STORAGE --query id -o tsv)
for MI in $(az identity list --resource-group $RG --query "[].principalId" -o tsv); do
  az role assignment create --assignee $MI --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ID/blobServices/default/containers/mydata" -o none
done
```

## Step 7: Run Discovery

```bash
curl -s -H "Authorization: Bearer my-api-key" \
  "http://localhost:6066/v1/discover?prefix=abfss://mydata@${STORAGE}.dfs.core.windows.net/"
```

## Step 8: Run Crunch

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

Note the `submissionId` from the response.

## Step 9: Monitor

```bash
SID="driver-XXXXX"  # from step 8

# Poll status
curl -s "http://localhost:6066/v1/submissions/status/$SID" -H "Authorization: Bearer my-api-key"

# Watch pods
kubectl get pods -n forge -w

# Driver logs
kubectl logs -f -n forge -l spark-role=driver
```

States: `SUBMITTED` → `RUNNING` → `FINISHED` (success) or `FAILED`

## Console UI

```bash
kubectl port-forward svc/forge-api 6066:6066 -n forge &
# Open http://localhost:6066/console/ in browser (not available from Cloud Shell)
```

## Image overrides

Image versions are set by `granica-release-images.tfvars`. To override for testing:

```bash
terraform apply -var-file=granica-release-images.tfvars -var-file=forge-local.tfvars \
  -var="forge_api_image=granicaaz.azurecr.io/forge-api:v0.6.21-alpha" \
  -var="crunch_image=granicaaz.azurecr.io/crunch:v0.6.21-alpha-azure3" \
  -var="spark_image=granicaaz.azurecr.io/crunch:v0.6.21-alpha-spark"
```

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

## Outputs

| Output | Description |
|--------|-------------|
| `forge_api_endpoint` | `rest://<ip>:6066` |
| `cluster_name` | AKS cluster name |
| `kubeconfig_command` | `az aks get-credentials` command |
| `storage_account_name` | Storage Account name for `abfss://` URIs |
| `resource_group_name` | Resource group name |
| `deploy_mode` | `customer` or `hosted` |

## Variables reference

See `variables.tf` for all inputs. Key ones:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `subscription_id` | Yes | — | Azure subscription ID |
| `cluster_name` | No | `forge` | AKS cluster name |
| `region` | No | `eastus2` | Azure region |
| `mode` | No | `customer` | `customer` or `hosted` |
| `vm_size_system` | No | `Standard_D2as_v7` | System pool VM size |
| `vm_size_spark_driver` | No | `Standard_F4as_v7` | Spark driver VM size |
| `vm_size_spark_executor` | No | `Standard_F4as_v7` | Spark executor (Spot) VM size |
| `arch` | No | `amd64` | CPU architecture |
| `storage_container_names` | No | `[]` | Additional storage containers for RBAC |

## Teardown

See [TEARDOWN.md](TEARDOWN.md).
