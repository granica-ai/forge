# Deploy Forge on Azure — Terraform

This guide explains how to deploy Granica Forge on Azure using the published Terraform module. Use this method when you want a repeatable, declarative deployment and don't need to customize individual resources outside of the module's variables.

If you need tighter control over each Azure resource or need to integrate with existing infrastructure that the module doesn't know about, see the [manual deployment guide](manual_deployment.md) instead.

## What gets deployed

The module provisions the same components as the manual flow:

| Component | Purpose |
|---|---|
| Resource Group | Container for all Forge resources (`granica-<cluster_name>-rg` by default) |
| Virtual Network | Network isolation for AKS nodes, with NAT Gateway for predictable egress |
| AKS Cluster | Kubernetes control plane with two node pools (on-demand and spot) |
| ADLS Gen2 Storage Account | Forge system storage (job history, metrics, recipes) |
| Managed Identity | Single identity shared by the `forge-api` and `spark-driver` service accounts for credential-free access to Azure resources via Workload Identity |
| Helm Charts | Spark Operator, Prometheus + Grafana, and forge-api |
| ForgeJob CRD | Custom resource for Forge jobs, applied directly from the module |

## Prerequisites

- Terraform `>= 1.9`
- `az` CLI (used to authenticate Terraform to Azure)
- `kubectl` (used by the module's ForgeJob CRD apply step)
- `helm` (optional — only if you want to inspect the deployed chart)

### Required Permissions for Deployment

The Azure identity running Terraform needs:
- **Contributor** (create/read/update/delete Azure resources)
- **User Access Administrator** (assign Storage Blob Data Contributor to the Forge Managed Identity)

### Required credentials from Granica

Before you start, obtain the following from Granica:
- Docker-registry username and password for pulling the Forge images

---

## Step 1: Authenticate to Azure

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

(Optional) To authenticate Terraform with a Service Principal, set the following environment variables:

```bash
export ARM_SUBSCRIPTION_ID="<subscription-id>"
export ARM_TENANT_ID="<tenant-id>"
export ARM_CLIENT_ID="<sp-client-id>"
export ARM_CLIENT_SECRET="<sp-secret>"
```

The principal must have Contributor + User Access Administrator on the target subscription.

---

## Step 2: Clone the module

Clone the public Forge repository and change into the module directory:

```bash
git clone --depth 1 --branch v0.9.4-delta-optimize-1d8cf787 https://github.com/granica-ai/forge.git
cd forge/terraform/forge-azure
```

---

## Step 3: Configure variables

Create a `terraform.tfvars` file with your values. Both `image_pull_secret_username` and `image_pull_secret_password` are **required** — Terraform errors at plan time if either is missing so the cluster never starts up with an empty pull secret. Everything else has sensible defaults.

```hcl
# ── Required ────────────────────────────────────────────────────────────────
image_pull_secret_username = "GRANICA_PROVIDED_USERNAME"
image_pull_secret_password = "GRANICA_PROVIDED_PASSWORD"

# ── Common overrides ────────────────────────────────────────────────────────
# cluster_name             = "forge"                # prefix for all resources
# region                   = "eastus2"
# subscription_id          = "..."                  # falls back to current az context
# release_version          = "v0.9.4-delta-optimize-1d8cf787"      # Forge release (templated at publish)
# image_tag                = ""                     # derived from release_version + arch
# image_repository         = "granicaaz.azurecr.io"
# image_pull_secret_name   = "forge-pull-secret"
# arch                     = "amd64"                # amd64 | arm64 (must match VM family)
# kubernetes_version       = "1.34"
# vm_size_on_demand        = "Standard_D4as_v7"     # system + forge-api + drivers
# vm_size_on_spot          = "Standard_D8as_v7"     # spark executors
# on_demand_pool_max_count = 4
# on_spot_pool_max_count   = 100
# mode                     = "customer"             # customer | hosted
# storage_container_names  = ["customer-data"]      # scope RBAC in customer mode

# ── Bring-your-own network (optional) ────────────────────────────────────────
# vnet_id   = "/subscriptions/.../virtualNetworks/my-vnet"
# subnet_id = "/subscriptions/.../subnets/my-subnet"
# pod_cidr, service_cidr, dns_service_ip also available

# ── Namespaces (rarely changed) ──────────────────────────────────────────────
# forge_namespace          = "forge"
# spark_operator_namespace = "crunch"
# monitoring_namespace     = "monitoring"
```

### Sensitive values via env var

To avoid committing credentials, prefer env vars:

```bash
export TF_VAR_image_pull_secret_password="$(cat ~/.granica/acr-token)"
```

### Retrieving the auto-generated API key

If you leave `api_key` unset, the module generates a random 32-char key.
After `terraform apply`, retrieve it with:

```bash
terraform output -raw api_key
```

The key is stored (sensitive) in Terraform state and in the `forge-api-keys`
Kubernetes secret.

### Full variable reference

See `variables.tf` in the module for every knob (CIDRs, pool max counts, chart versions, chart/CRD paths, namespace overrides, etc.). All have sensible defaults; only the required fields above need to be set.

---

## Step 4: Init and plan

```bash
terraform init
terraform plan -out tfplan
```

Review the plan output carefully — it lists every resource the module will create. Typical plan for a fresh deployment is ~40 resources across Resource Group, VNet, AKS, Managed Identity, Storage, and three Helm releases.

---

## Step 5: Apply

```bash
terraform apply tfplan
```

Apply takes ~15–20 minutes.

---

## Step 6: Verify the deployment

Configure `kubectl` against the new cluster:

```bash
az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw cluster_name)
```

### Check pod status

List all Forge-related pods across namespaces:

```bash
kubectl get pods -A | grep -E "forge|crunch|monitoring"
```

All pods should show `Running` (or `2/2`, `3/3` for multi-container pods). The forge-api pod may take 30–60 seconds to start on first deploy while it pulls the container image and initializes.

If any pod shows `ImagePullBackOff`, verify that `image_pull_secret_username` and `image_pull_secret_password` in your tfvars are correct.

### Health check

The forge-api exposes a `/healthz` endpoint that returns the API status, queue depth, and running job count. Run a health check from inside the cluster using the internal service DNS name:

```bash
kubectl run health-check --rm -it --restart=Never --image=busybox -n forge -- \
  sh -c "wget -qO- http://forge-api.forge.svc.cluster.local:6066/healthz"
```

Expected response:

```json
{"historyEnabled":false,"queued":0,"running":0,"status":"ok"}
```

If the status is `ok`, the Forge deployment is ready to accept jobs.

### Run Discovery

Discovery scans an ADLS Gen2 path and identifies Parquet, Delta Lake, and Iceberg tables. It returns table format, file count, total size, and last modified time.

Replace the `abfss://` path with the location of your data, and set `STORAGE_ACCOUNT` to the storage account name output by Terraform (or your own). `API_KEY` is the value you set in your tfvars.

```bash
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
API_KEY="<value you set in tfvars>"

kubectl run discovery --rm -it --restart=Never --image=busybox -n forge -- \
  sh -c "wget -qO- 'http://forge-api.forge.svc.cluster.local:6066/v1/discover?prefix=abfss://testdata@${STORAGE_ACCOUNT}.dfs.core.windows.net/forge-qa/crunch-test/snappy_parquet/' --header='Authorization: Bearer ${API_KEY}'"
```

The response lists discovered tables with their format and size. If you see `access_denied`, verify that the Forge Managed Identity has `Storage Blob Data Contributor` access to the storage account containing your data.

### Run Crunch

Crunch compresses your Parquet data using adaptive compression. The `--auto-learn` flag tells Forge to learn an optimal compression recipe from your data and apply it in a single job.

```bash
kubectl run crunch --rm -it --restart=Never --image=busybox -n forge -- \
  sh -c "wget -qO- --post-data='{\"mainClass\":\"com.granica.forge.ForgeOptimizer\",\"appResource\":\"local:///opt/spark/jars/crunch-spark-assembly-0.7.0.jar\",\"appArgs\":[\"--table-path\",\"abfss://testdata@${STORAGE_ACCOUNT}.dfs.core.windows.net/forge-qa/crunch-test/snappy_parquet/\",\"--auto-learn\"],\"sparkProperties\":{\"spark.granica.enabled\":\"true\"}}' --header='Authorization: Bearer ${API_KEY}' --header='Content-Type: application/json' 'http://forge-api.forge.svc.cluster.local:6066/v1/submissions/create'"
```

The response includes a `submissionId` that you can use to track the job.

### Monitor jobs

Track a running job's status, watch pod lifecycle, or tail logs from the Spark driver and crunch-worker sidecar:

```bash
# Check job status (replace SUBMISSION_ID with the submissionId from the crunch response)
kubectl run status --rm -it --restart=Never --image=busybox -n forge -- \
  sh -c "wget -qO- --header='Authorization: Bearer ${API_KEY}' 'http://forge-api.forge.svc.cluster.local:6066/v1/submissions/status/SUBMISSION_ID'"

# Watch pod lifecycle
kubectl get pods -n forge -w

# Spark driver logs (job progress, errors)
kubectl logs -f -n forge -l spark-role=driver

# Crunch worker logs (compression results, DRR)
kubectl logs -f -n forge -l spark-role=executor -c crunch-worker
```

Job states: `SUBMITTED` → `RUNNING` → `FINISHED` (success) or `FAILED`.

---

## Teardown

```bash
terraform destroy
```

Destroy removes the AKS cluster, managed identity, and RBAC role assignments. It also removes the Storage Account and all containers — **your Forge system data (history, metrics, recipes) will be deleted.** If you want to keep that data, set `prevent_destroy = true` on `azurerm_storage_account.forge` before destroying, or import the account into a separate module.

If `terraform destroy` hangs (e.g. on AKS deletion or a stuck namespace finalizer), you can force-delete the resource group directly:

```bash
az group delete --name $(terraform output -raw resource_group_name) --yes --no-wait
```

---

## FAQ

### How do I upgrade to a new Forge release?

Bump `image_tag` in your tfvars and run `terraform apply`. Only the Helm release is updated; infrastructure is untouched.

### Can I use my own VNet?

Yes — set `vnet_id` and `subnet_id`. The module skips VNet / NAT Gateway creation and attaches AKS to your existing subnet.

### Can the ACR live in a different subscription?

Yes. The module only creates a Kubernetes docker-registry secret from the credentials you provide — it doesn't touch ACR RBAC, so the ACR can be anywhere your pull credentials work.
