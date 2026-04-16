# Deploy Forge on Azure — Manual Configuration

This guide explains how to deploy Granica Forge on Azure using manually created resources. Use this method if you want full control over each Azure resource, need to integrate with existing infrastructure, or need custom configurations that go beyond the Terraform module.

This guide assumes you are running from Azure Cloud Shell (shell.azure.com), which has the Azure CLI, kubectl, and helm pre-installed.

## What gets deployed

Forge on Azure consists of the following components:

| Component | Purpose |
|---|---|
| Resource Group | Container for all Forge resources |
| Virtual Network | Network isolation for AKS nodes, with NAT Gateway for predictable egress |
| AKS Cluster | Kubernetes control plane with two node pools (on-demand and spot) |
| ADLS Gen2 Storage Account | Forge system storage (job history, metrics, recipes) |
| Managed Identities | Two identities (forge-api and spark-driver) for credential-free access to Azure resources via Workload Identity |
| Helm Charts | Spark Operator, Prometheus + Grafana, and forge-api |

## Prerequisites

- Azure Cloud Shell (or a local environment with `az`, `kubectl`, and `helm` installed)

### Required Permissions for Deployment

To successfully deploy and configure resources, your Azure identity must have the following roles:
- **Contributor**
- **User Access Administrator**

---

## Step 1: Set variables

Before you begin, gather the following values. These variables are referenced throughout the deployment and must be set in your Cloud Shell session.

### Required variables

- **`SUBSCRIPTION_ID`** — Your Azure subscription ID. This is the subscription where all Forge resources will be created. To find it, go to the Azure Portal > Subscriptions, or run:
  ```bash
  az account list -o table
  ```
- **`REGION`** — The Azure region where Forge will be deployed. Choose a region close to your data to minimize latency. Common options: `eastus2`, `westus2`, `centralus`.
- **`CLUSTER_NAME`** — A name for your Forge deployment. Used as a prefix for all Azure resources (resource group, AKS cluster, storage account, managed identities). Must be lowercase alphanumeric. Examples: `forge`, `forge-prod`, `mycompany-forge`.
- **`API_KEY`** — An authentication token for the Forge REST API. Every API call (discovery, job submission, status checks) requires this token in the `Authorization: Bearer` header. Choose any string for development. For production, generate a strong random key:
  ```bash
  openssl rand -hex 32
  ```
- **`ACR_NAME`**, **`ACR_USERNAME`**, **`ACR_PASSWORD`** — Credentials for pulling Forge container images from the Azure Container Registry. These are provided by Granica during onboarding. The username and password are a read-only pull token scoped to the Forge image repositories.

### Set all variables

```bash
SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
REGION="eastus2"
CLUSTER_NAME="forge"
API_KEY="your-api-key"
ACR_NAME="granicaaz"
ACR_USERNAME="GRANICA_PROVIDED_USERNAME"
ACR_PASSWORD="GRANICA_PROVIDED_PASSWORD"

RESOURCE_GROUP="forge-${CLUSTER_NAME}-rg"
STORAGE_ACCOUNT="forge${CLUSTER_NAME//[-]/}${REGION//[-]/}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"
VNET_NAME="${CLUSTER_NAME}-vnet"
SUBNET_NAME="aks-subnet"

az account set --subscription $SUBSCRIPTION_ID
```

---

## Step 2: Create Resource Group

All Forge resources are placed in a single resource group for easy management and teardown.

```bash
az group create --name $RESOURCE_GROUP --location $REGION --tags "forge.granica.ai-managed=true"
```

---

## Step 3: Create Virtual Network

Forge requires a VNet with a subnet for AKS nodes and a NAT Gateway for predictable outbound connectivity. The NAT Gateway ensures all egress traffic uses a static public IP, which is required for firewall allowlisting and storage access.

If you have an existing VNet you want to use, skip this step and set `SUBNET_ID` to your existing subnet's resource ID.

### Create VNet and subnet

```bash
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefixes 10.0.0.0/16 \
  --location $REGION

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --address-prefixes 10.0.0.0/20
```

### Create NAT Gateway

```bash
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-nat-ip" \
  --sku Standard \
  --allocation-method Static

az network nat gateway create \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-nat" \
  --public-ip-addresses "${CLUSTER_NAME}-nat-ip" \
  --idle-timeout 10
```

### Attach NAT Gateway to subnet

```bash
SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --query id -o tsv)

az network vnet subnet update \
  --ids $SUBNET_ID \
  --nat-gateway "${CLUSTER_NAME}-nat"
```

---

## Step 4: Create AKS Cluster

Forge uses an AKS cluster with two node pools:

- **On-demand pool** — Runs the Forge control plane (forge-api, Spark Operator, Prometheus), Spark drivers, and other platform services. These workloads need reliable, uninterruptible compute. The autoscaler adds nodes when Spark drivers are scheduled and removes them when idle, so cost scales with usage.
- **Spot pool** — Runs Spark executors, which perform the actual data compression. Executors are stateless and can tolerate eviction, making them ideal for Spot instances at reduced cost. Starts at zero nodes and scales up automatically when jobs are submitted.

### Node sizing

A Spark executor pod requires approximately 3 vCPUs and 10 GiB of memory (1 CPU + 4.5 GiB for the Spark process, plus 2 CPU + 6 GiB for the crunch-worker sidecar that performs compression). Choose VM sizes that can fit at least one executor per node. We recommend a minimum of 4 vCPUs and 16 GiB per node.

Recommended VM sizes:

| VM Size | vCPUs | Memory | Use case |
|---|---|---|---|
| Standard_D4as_v7 | 4 | 16 GiB | Minimum recommended for both pools |
| Standard_D8as_v7 | 8 | 32 GiB | Higher throughput — fits 2 executors per node |
| Standard_D16as_v7 | 16 | 64 GiB | Large-scale workloads |
| Standard_F8s_v2 | 8 | 16 GiB | Compute-optimized alternative |

You can use different VM sizes for the on-demand and Spot pools. For example, use `Standard_D4as_v7` for on-demand (platform services + drivers) and `Standard_D8as_v7` for Spot (executors) to optimize cost and throughput.

### Required settings

The following settings must be enabled for Forge to function. Do not change or omit these:

| Setting | Why it's required |
|---|---|
| `--enable-oidc-issuer` | Required for Workload Identity — allows K8s service accounts to authenticate as Azure managed identities |
| `--enable-workload-identity` | Enables the Workload Identity webhook that injects Azure tokens into pods |
| `--network-plugin azure` with `--network-plugin-mode overlay` | Azure CNI Overlay provides scalable pod networking without consuming VNet IPs per pod |
| `--outbound-type userAssignedNATGateway` | Ensures predictable egress IP for storage and registry access |
| `--nodepool-labels nodeUse=granica-on-demand` | Forge uses this label to schedule drivers and platform services on on-demand nodes |

### Customizable settings

The following settings can be modified to fit your environment:

| Setting | Default | Notes |
|---|---|---|
| `--kubernetes-version` | `1.34` | Any AKS-supported version >= 1.30. Check available versions: `az aks get-versions --location $REGION -o table` |
| `--node-vm-size` | `Standard_D4as_v7` | Any VM with >= 4 vCPUs and >= 16 GiB. See recommended VMs above. |
| `--pod-cidr` | `10.48.0.0/16` | Must not overlap with VNet CIDR or service CIDR. Change if it conflicts with your network. |
| `--service-cidr` | `10.47.128.0/20` | Internal K8s service IP range. Must not overlap with VNet or pod CIDR. |
| `--dns-service-ip` | `10.47.128.10` | Must be within the service CIDR range. |
| `--node-osdisk-size` | `100` GB | Increase for workloads with large local shuffle data. |
| `--min-count` / `--max-count` | `1` / `4` | Autoscaler bounds. Adjust based on expected concurrency. |
| `--vnet-subnet-id` | Created in Step 3 | Use your own subnet if integrating with an existing VNet. |
| `--generate-ssh-keys` | Auto-generates | Omit if you want to provide your own SSH key via `--ssh-key-value`. |

### Create the cluster with on-demand node pool

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $REGION \
  --kubernetes-version 1.34 \
  --node-count 1 \
  --min-count 1 \
  --max-count 4 \
  --enable-cluster-autoscaler \
  --node-vm-size Standard_D4as_v7 \
  --vnet-subnet-id $SUBNET_ID \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --pod-cidr 10.48.0.0/16 \
  --service-cidr 10.47.128.0/20 \
  --dns-service-ip 10.47.128.10 \
  --outbound-type userAssignedNATGateway \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --node-osdisk-size 100 \
  --nodepool-labels nodeUse=granica-on-demand \
  --generate-ssh-keys \
  --tags "forge.granica.ai-managed=true"
```

### Add Spot node pool

The Spot pool starts with zero nodes and scales up automatically when Spark executors are scheduled. Nodes are evicted when Azure reclaims capacity, and the autoscaler replaces them. Set `--max-count` based on your expected concurrency — each executor pod occupies one node.

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name spot \
  --node-vm-size Standard_D4as_v7 \
  --node-count 0 \
  --min-count 0 \
  --max-count 100 \
  --enable-cluster-autoscaler \
  --node-osdisk-size 100 \
  --vnet-subnet-id $SUBNET_ID \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \
  --labels nodeUse=granica-on-spot \
  --node-taints "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
```

### Get cluster credentials

Download the kubeconfig for your new cluster so kubectl commands target it:

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --overwrite-existing
```

Verify the cluster is accessible and the on-demand node is ready:

```bash
kubectl get nodes
```

You should see one node from the on-demand pool in `Ready` state. The Spot pool has zero nodes until executors are scheduled — this is expected.

---

## Step 5: Create Image Pull Secret

Forge container images are hosted in a private Azure Container Registry. To allow your AKS cluster to pull these images, create a Kubernetes secret with the credentials provided by Granica.

The secret must exist in both the `forge` namespace (for forge-api and Spark drivers) and the `crunch` namespace (for the Spark Operator).

```bash
kubectl create namespace forge

kubectl create secret docker-registry forge-pull-secret \
  --namespace forge \
  --docker-server=${ACR_NAME}.azurecr.io \
  --docker-username=$ACR_USERNAME \
  --docker-password=$ACR_PASSWORD

kubectl create namespace crunch

kubectl create secret docker-registry forge-pull-secret \
  --namespace crunch \
  --docker-server=${ACR_NAME}.azurecr.io \
  --docker-username=$ACR_USERNAME \
  --docker-password=$ACR_PASSWORD
```

---

## Step 6: Create Storage Account

Forge uses an ADLS Gen2 storage account with hierarchical namespace (HNS) enabled for its system data — job history, compression recipes, and metrics. This is Forge's internal working storage, separate from your customer data.

```bash
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $REGION \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --hns true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --tags "forge.granica.ai-managed=true"

az storage container create \
  --account-name $STORAGE_ACCOUNT \
  --name system \
  --auth-mode login
```

---

## Step 7: Create Managed Identities

Forge uses Azure Workload Identity for credential-free authentication. Two managed identities are created:

- **forge-api** — Used by the Forge control plane for discovery, reading/writing system data, and managing jobs.
- **spark-driver** — Used by Spark driver and executor pods for reading customer data and writing compressed output.

Each identity is linked to a Kubernetes service account via a federated credential, which allows pods to authenticate as the identity without storing any secrets.

### Create the identities

```bash
az identity create \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-forge-api" \
  --location $REGION

az identity create \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-spark-driver" \
  --location $REGION
```

### Retrieve identity details

Each managed identity has two IDs:
- **Client ID** — identifies the identity when configuring Workload Identity (used in Kubernetes annotations and Helm values)
- **Principal ID** — identifies the identity when assigning Azure RBAC roles (used in `az role assignment create`)

Both are auto-generated by Azure. The following commands store them in shell variables for use in later steps.

```bash
FORGE_API_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-forge-api" \
  --query clientId -o tsv)

FORGE_API_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-forge-api" \
  --query principalId -o tsv)

SPARK_DRIVER_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-spark-driver" \
  --query clientId -o tsv)

SPARK_DRIVER_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "${CLUSTER_NAME}-spark-driver" \
  --query principalId -o tsv)

OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query oidcIssuerProfile.issuerUrl -o tsv)
```

### Create federated identity credentials

Federated credentials establish trust between a Kubernetes service account and an Azure managed identity via the AKS OIDC issuer. When a pod runs with the linked service account, the Workload Identity webhook automatically injects an Azure access token — no secrets or credentials are stored in the cluster.

```bash
az identity federated-credential create \
  --resource-group $RESOURCE_GROUP \
  --identity-name "${CLUSTER_NAME}-forge-api" \
  --name "forge-api-sa" \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:forge:forge-api" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --resource-group $RESOURCE_GROUP \
  --identity-name "${CLUSTER_NAME}-spark-driver" \
  --name "spark-driver-sa" \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:forge:spark-driver" \
  --audiences "api://AzureADTokenExchange"
```

---

## Step 8: Grant Storage Access

Grant both managed identities data plane access to the Forge storage account, plus an additional narrow grant on the `system` container for the `spark-driver` identity:

- **`Storage Blob Data Contributor` at the storage account scope** (both identities) — read/write access to data in all containers. Sufficient for normal Forge operations.
- **`Storage Blob Data Owner` scoped only to the `system` container** (spark-driver only) — required so Spark can write its event logs to Forge's internal storage. Scoping it to the `system` container keeps the elevated permission off your data containers.

```bash
STORAGE_ID=$(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)
SYSTEM_CONTAINER_SCOPE="${STORAGE_ID}/blobServices/default/containers/system"

az role assignment create \
  --assignee-object-id "$FORGE_API_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID"

az role assignment create \
  --assignee-object-id "$SPARK_DRIVER_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID"

az role assignment create \
  --assignee-object-id "$SPARK_DRIVER_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner" \
  --scope "$SYSTEM_CONTAINER_SCOPE"
```

> **Note:** Azure RBAC role assignments can take 2-5 minutes to propagate. If you see `access_denied` errors in later steps, wait a few minutes and retry.

---

## Step 9: Install Forge Components

This step installs three Helm charts and applies the ForgeJob custom resource definition.

Forge depends on two open-source components that are installed separately:
- **Spark Operator** — a CNCF project that manages Spark job lifecycle on Kubernetes. Installed separately so customers can use their preferred version or share an existing operator across workloads.
- **Prometheus + Grafana** — standard Kubernetes monitoring stack. Installed separately so customers can integrate with their existing observability infrastructure or skip it entirely.

These are not bundled in the Forge chart to avoid version conflicts with existing installations and to give customers full control over their monitoring and Spark infrastructure.

### Clone the Forge repo

```bash
git clone --depth 1 --branch v0.0.0-alpha-citest1 https://github.com/granica-ai/forge.git ~/forge
```

### Install Spark Operator

The Spark Operator watches for SparkApplication custom resources and manages the lifecycle of Spark driver and executor pods. It is installed in the `crunch` namespace.

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

helm install spark-operator spark-operator/spark-operator \
  --namespace crunch \
  --version 2.4.0 \
  --set webhook.enable=true \
  --set "spark.jobNamespaces[0]=" \
  --set "controller.env[0].name=JAVA_TOOL_OPTIONS" \
  --set "controller.env[0].value=-Dkubernetes.auth.tryKubeConfig=false" \
  --set "spark.sparkConf[0].name=spark.kubernetes.master" \
  --set "spark.sparkConf[0].value=k8s://https://kubernetes.default.svc:443"
```

### Install Prometheus and Grafana

Prometheus collects metrics from Forge and Spark jobs. Grafana provides dashboards for monitoring job throughput, DRR (Data Reduction Ratio), and cluster health.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 82.2.1 \
  --set grafana.enabled=true \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

### Apply ForgeJob CRD and create API key secret

The ForgeJob custom resource definition (CRD) extends Kubernetes with a `ForgeJob` resource type that tracks each compression job's lifecycle — submission, execution, completion, and results (DRR, rows processed, duration). Without this CRD, the forge-api cannot create or monitor jobs.

The API key secret is a Kubernetes secret that stores the authentication token for the Forge REST API. The forge-api pod mounts this secret and validates every incoming request against it.

```bash
kubectl apply -f ~/forge/k8s/forgejob-crd.yaml

kubectl create secret generic forge-api-keys \
  --namespace forge \
  --from-literal=keys="$API_KEY"
```

### Install forge-api

The forge-api Helm chart deploys the Forge control plane — a Go REST API that handles table discovery, job submission and scheduling, compression recipe management, and the web console. It communicates with the Spark Operator to create SparkApplication resources, which in turn launch Spark driver and executor pods.

The service account annotations configure Workload Identity (linking the K8s service account to the Azure managed identity), and the image pull secrets enable pulling from the private ACR. All configuration is passed inline so no manual patching or pod restarts are needed after install.

```bash
helm install forge-api ~/forge/helm/forge-api \
  --namespace forge \
  --set cloud=azure \
  --set "nodeSelector.kubernetes\.io/arch=amd64" \
  --set image.repository=${ACR_NAME}.azurecr.io/forge-api \
  --set image.tag=v0.0.0-alpha-citest1 \
  --set "imagePullSecrets[0].name=forge-pull-secret" \
  --set env.FORGE_CLOUD_PROVIDER=azure \
  --set env.AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  --set env.AZURE_SPARK_CLIENT_ID=$SPARK_DRIVER_CLIENT_ID \
  --set env.FORGE_SPARK_IMAGE=${ACR_NAME}.azurecr.io/crunch:v0.0.0-alpha-citest1-spark \
  --set env.FORGE_CRUNCH_IMAGE=${ACR_NAME}.azurecr.io/crunch:v0.0.0-alpha-citest1 \
  --set env.FORGE_DEFAULT_APP_RESOURCE="local:///opt/spark/jars/crunch-spark-assembly-0.7.0.jar" \
  --set env.FORGE_SYSTEM_BUCKET=system \
  --set env.FORGE_EXECUTOR_NODE_SELECTOR='\{"nodeUse":"granica-on-spot"\}' \
  --set env.FORGE_EXECUTOR_TOLERATIONS='\[\{"key":"kubernetes.azure.com/scalesetpriority"\,"operator":"Equal"\,"value":"spot"\,"effect":"NoSchedule"\}\]' \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$FORGE_API_CLIENT_ID" \
  --set "sparkDriver.serviceAccount.annotations.azure\.workload\.identity/client-id=$SPARK_DRIVER_CLIENT_ID"
```

---

## Step 10: Optional: Expose Forge API / Console Publicly (HTTP)

By default, the forge-api service is only accessible within the Kubernetes cluster (ClusterIP).

If you want to access the Forge API or console from outside the cluster (e.g., for testing or demos), you can expose it via a public Azure Load Balancer over HTTP.

### Expose via HTTP (Port 80)

Run the following command to update the service:

```bash
kubectl patch svc forge-api -n forge \
  -p '{
    "spec": {
      "type": "LoadBalancer",
      "ports": [
        {"name":"http","port":80,"targetPort":6066,"protocol":"TCP"},
        {"name":"rest","port":6066,"targetPort":6066,"protocol":"TCP"}
      ]
    }
  }'
```

This will:
- Change the service type to `LoadBalancer`
- Expose the service publicly on port 80
- Continue serving traffic internally on port 6066

### Retrieve the Public Endpoint

After applying the patch, run:

```bash
kubectl get svc forge-api -n forge
```

Wait for the `EXTERNAL-IP` field to be populated (this may take a few minutes). Once available, you can access: `http://<EXTERNAL-IP>`

> **Notes:**
> - This exposes the service publicly over HTTP (unencrypted).
> - Suitable for development, testing, or temporary access.
> - Not recommended for production use without additional security controls.

### HTTPS / TLS (Recommended for Production)

To expose the service securely over HTTPS, use an Ingress controller (e.g., NGINX or Azure Application Gateway) with TLS termination. This typically involves deploying an ingress controller, configuring a DNS name, and attaching a TLS certificate (e.g., via Let's Encrypt using cert-manager).

---

## Step 11: Verify the deployment

After all Helm charts are installed, verify that the Forge platform is running correctly. This step confirms that the control plane, Spark Operator, and monitoring stack are all healthy before you submit any jobs.

### Check pod status

List all Forge-related pods across namespaces:

```bash
kubectl get pods -A | grep -E "forge|crunch|monitoring"
```

All pods should show `Running` (or `2/2`, `3/3` for multi-container pods). The forge-api pod may take 30–60 seconds to start on first deploy while it pulls the container image and initializes.

If any pod shows `ImagePullBackOff`, verify that the image pull secret was created correctly in Step 5 and that the ACR credentials are valid.

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

Replace the `abfss://` path with the location of your data. The shell variables from Step 1 are substituted automatically.

```bash
kubectl run discovery --rm -it --restart=Never --image=busybox -n forge -- \
  sh -c "wget -qO- 'http://forge-api.forge.svc.cluster.local:6066/v1/discover?prefix=abfss://testdata@${STORAGE_ACCOUNT}.dfs.core.windows.net/forge-qa/crunch-test/snappy_parquet/' --header='Authorization: Bearer ${API_KEY}'"
```

The response lists discovered tables with their format and size. If you see `access_denied`, verify that the managed identities have `Storage Blob Data Contributor` access to the storage account containing your data (Step 8).

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

To remove all Forge resources from your subscription, run the following commands. This process removes Helm releases first (to clean up K8s-managed resources like load balancers and persistent volumes), then deletes the AKS cluster and resource group.

```bash
# Remove Helm releases
helm uninstall forge-api -n forge
helm uninstall spark-operator -n crunch
helm uninstall kube-prometheus-stack -n monitoring

# Remove CRDs
kubectl delete crd forgejobs.forge.granica.ai 2>/dev/null

# Delete AKS cluster (runs in background)
az aks delete --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --no-wait

# Delete the entire resource group (VNet, storage, identities, NAT gateway)
az group delete --name $RESOURCE_GROUP --no-wait
```

This deletes the AKS cluster, all node pools, the VNet, NAT gateway, storage account, managed identities, and the resource group itself. Data in external storage accounts (your customer data) is not affected — only the Forge system storage account is removed.

---

## FAQ

### Why are both Contributor and User Access Administrator roles required?

The Contributor role allows you to create and manage Azure resources such as AKS clusters, storage accounts, and networking components. However, it does not grant permission to manage access or assign roles.

The User Access Administrator role complements this by allowing you to create and manage role assignments (RBAC). This is required for steps such as granting identities access to storage accounts or assigning permissions to AKS-managed identities (for example, allowing a cluster to use a subnet).

Together, these roles ensure that you can both provision infrastructure and configure the necessary access permissions required for the deployment to function correctly.

### What scope should the roles be granted at?

At minimum, both roles should be granted at the resource group level used for deployment.

For stricter least-privilege setups, User Access Administrator may be scoped to specific resources (e.g., subnet or storage account), but this may require additional coordination during deployment.

### What are the derived variables in the deployment script?

The following variables are computed from the required variables (`CLUSTER_NAME`, `REGION`) and do not need to be changed unless your environment requires custom naming.

| Variable | Default value | Description |
|---|---|---|
| `RESOURCE_GROUP` | `forge-{CLUSTER_NAME}-rg` | Azure resource group containing all Forge resources |
| `STORAGE_ACCOUNT` | `forge{CLUSTER_NAME}{REGION}` (max 24 chars) | ADLS Gen2 storage account for Forge system data. Must be globally unique. |
| `VNET_NAME` | `{CLUSTER_NAME}-vnet` | Virtual network for AKS cluster networking |
| `SUBNET_NAME` | `aks-subnet` | Subnet within the VNet where AKS nodes are placed |
