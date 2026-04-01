# Deploy Forge on Azure — Manual Configuration

This guide explains how to deploy Forge on Azure using manually created resources. Use this method if you want full control over each Azure resource, need custom configurations, or cannot use Terraform.

This guide assumes you are running from **Azure Cloud Shell** (`shell.azure.com`).

## Prerequisites

- Azure subscription with Contributor access
- `kubectl` (pre-installed in Cloud Shell)
- `helm` (pre-installed in Cloud Shell)
- Sufficient vCPU quota in your target region (~12 on-demand vCPUs)

## Overview

Forge on Azure requires the following resources, created in this order:

1. Resource Group
2. Virtual Network + Subnet + NAT Gateway
3. AKS Cluster + Node Pools
4. ACR Access (image pull permission)
5. ADLS Gen2 Storage Account + Container
6. Managed Identities + Federated Credentials
7. Storage RBAC Role Assignments
8. Helm Charts (Spark Operator, Prometheus, forge-api)
9. ForgeJob CRD + API Key Secret

---

## Step 1: Set variables

Set these once. All subsequent commands reference them.

```bash
# Required — change these
SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
REGION="eastus2"
CLUSTER_NAME="forge"
API_KEY="your-api-key"

# ACR where Forge images are published
ACR_NAME="granicaaz"
ACR_RG="granica-dev-rg"

# Derived — do not change
RESOURCE_GROUP="forge-${CLUSTER_NAME}-rg"
STORAGE_ACCOUNT="forge${CLUSTER_NAME}${REGION//[-]/}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"  # Max 24 chars
VNET_NAME="${CLUSTER_NAME}-vnet"
SUBNET_NAME="aks-subnet"

az account set --subscription $SUBSCRIPTION_ID
```

## Step 2: Create Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $REGION \
  --tags "forge.granica.ai-managed=true"
```

## Step 3: Create Virtual Network

### 3a. Create VNet and Subnet

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

### 3b. Create NAT Gateway (for predictable egress)

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

SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --query id -o tsv)

az network vnet subnet update \
  --ids $SUBNET_ID \
  --nat-gateway "${CLUSTER_NAME}-nat"
```

## Step 4: Create AKS Cluster

### 4a. Create the cluster with system node pool

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $REGION \
  --kubernetes-version 1.32 \
  --node-count 1 \
  --min-count 1 \
  --max-count 4 \
  --enable-cluster-autoscaler \
  --node-vm-size Standard_D2as_v7 \
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
  --nodepool-labels forge.granica.ai/pool=system \
  --generate-ssh-keys \
  --tags "forge.granica.ai-managed=true"
```

### 4b. Add spark-driver node pool (on-demand)

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name sparkdriver \
  --node-vm-size Standard_F4as_v7 \
  --min-count 0 \
  --max-count 4 \
  --enable-cluster-autoscaler \
  --os-disk-size-gb 100 \
  --vnet-subnet-id $SUBNET_ID \
  --labels forge.granica.ai/pool=spark-driver
```

### 4c. Add spark-executor node pool (Spot)

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name sparkexec \
  --node-vm-size Standard_F4as_v7 \
  --min-count 0 \
  --max-count 8 \
  --enable-cluster-autoscaler \
  --os-disk-size-gb 100 \
  --vnet-subnet-id $SUBNET_ID \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \
  --labels forge.granica.ai/pool=spark-executor \
  --node-taints "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
```

### 4d. Add evaluator node pool (on-demand)

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name evaluator \
  --node-vm-size Standard_F4as_v7 \
  --min-count 0 \
  --max-count 2 \
  --enable-cluster-autoscaler \
  --os-disk-size-gb 100 \
  --vnet-subnet-id $SUBNET_ID \
  --labels forge.granica.ai/pool=evaluator
```

### 4e. Get cluster credentials

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --overwrite-existing

kubectl get nodes
```

## Step 5: Grant ACR Pull Access

Allow AKS to pull Forge images from the Azure Container Registry.

```bash
ACR_ID=$(az acr show --name $ACR_NAME --resource-group $ACR_RG --query id -o tsv)
KUBELET_IDENTITY=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query identityProfile.kubeletidentity.objectId -o tsv)

az role assignment create \
  --assignee $KUBELET_IDENTITY \
  --role AcrPull \
  --scope $ACR_ID
```

## Step 6: Create Storage Account (ADLS Gen2)

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

## Step 7: Create Managed Identities

### 7a. Create identities

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

### 7b. Get identity details

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

echo "forge-api Client ID:    $FORGE_API_CLIENT_ID"
echo "spark-driver Client ID: $SPARK_DRIVER_CLIENT_ID"
echo "OIDC Issuer:            $OIDC_ISSUER"
```

### 7c. Create federated identity credentials

These link the K8s service accounts to the Azure Managed Identities via OIDC.

```bash
# forge-api SA → forge-api MI
az identity federated-credential create \
  --resource-group $RESOURCE_GROUP \
  --identity-name "${CLUSTER_NAME}-forge-api" \
  --name "forge-api-sa" \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:forge:forge-api" \
  --audiences "api://AzureADTokenExchange"

# spark-driver SA → spark-driver MI
az identity federated-credential create \
  --resource-group $RESOURCE_GROUP \
  --identity-name "${CLUSTER_NAME}-spark-driver" \
  --name "spark-driver-sa" \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:forge:spark-driver" \
  --audiences "api://AzureADTokenExchange"
```

## Step 8: Grant Storage RBAC

Grant both Managed Identities access to the storage account.

```bash
STORAGE_ID=$(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)

# forge-api: read/write for discovery, history, metrics
az role assignment create \
  --assignee $FORGE_API_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID

# spark-driver: read/write for data access
az role assignment create \
  --assignee $SPARK_DRIVER_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID
```

> **Note:** RBAC propagation takes 2-5 minutes. Wait before proceeding.

## Step 9: Install Helm Charts

### 9a. Spark Operator

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

helm install spark-operator spark-operator/spark-operator \
  --namespace crunch \
  --create-namespace \
  --version 2.4.0 \
  --set webhook.enable=true \
  --set "spark.jobNamespaces[0]=" \
  --set "controller.env[0].name=JAVA_TOOL_OPTIONS" \
  --set "controller.env[0].value=-Dkubernetes.auth.tryKubeConfig=false" \
  --set "spark.sparkConf[0].name=spark.kubernetes.master" \
  --set "spark.sparkConf[0].value=k8s://https://kubernetes.default.svc:443"
```

### 9b. Prometheus + Grafana

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

### 9c. forge-api

Clone the Forge repo to get the Helm chart:

```bash
export FORGE_VERSION=v1.2.7
git clone --depth 1 --branch "${FORGE_VERSION}" https://github.com/granica-ai/forge.git /tmp/forge
```

Install:

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)

helm install forge-api /tmp/forge/helm/forge-api \
  --namespace forge \
  --create-namespace \
  --set cloud=azure \
  --set "nodeSelector.kubernetes\.io/arch=amd64" \
  --set image.repository=granicaaz.azurecr.io/forge-api \
  --set image.tag=v0.6.21-alpha \
  --set env.FORGE_CLOUD_PROVIDER=azure \
  --set env.AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  --set env.AZURE_SPARK_CLIENT_ID=$SPARK_DRIVER_CLIENT_ID \
  --set env.FORGE_SPARK_IMAGE=granicaaz.azurecr.io/crunch:v0.6.21-alpha-spark \
  --set env.FORGE_CRUNCH_IMAGE=granicaaz.azurecr.io/crunch:v0.6.21-alpha-azure4
```

## Step 10: Apply CRDs and Secrets

### 10a. ForgeJob CRD

```bash
kubectl apply -f /tmp/forge/k8s/forgejob-crd.yaml
```

### 10b. API Key Secret

```bash
kubectl create secret generic forge-api-keys \
  --namespace forge \
  --from-literal=keys="$API_KEY"
```

### 10c. Annotate Service Accounts for Workload Identity

```bash
# forge-api SA
kubectl annotate sa forge-api -n forge \
  azure.workload.identity/client-id=$FORGE_API_CLIENT_ID --overwrite
kubectl label sa forge-api -n forge \
  azure.workload.identity/use=true --overwrite

# spark-driver SA
kubectl annotate sa spark-driver -n forge \
  azure.workload.identity/client-id=$SPARK_DRIVER_CLIENT_ID --overwrite
kubectl label sa spark-driver -n forge \
  azure.workload.identity/use=true --overwrite
```

### 10d. Restart forge-api to pick up the secret and identity

```bash
kubectl rollout restart deployment forge-api -n forge
kubectl rollout status deployment forge-api -n forge --timeout=60s
```

## Step 11: Verify Deployment

```bash
# Check all pods
kubectl get pods -A | grep -E "forge|crunch|monitoring"

# Health check
kubectl port-forward svc/forge-api 6066:6066 -n forge &
sleep 3
curl -s http://localhost:6066/healthz
```

Expected: `{"status":"ok"}`

## Step 12: Grant Access to Customer Data

If your Parquet data is in a different storage account, grant the Forge identities access:

```bash
DATA_STORAGE_ACCOUNT="customer-storage-account"
DATA_CONTAINER="customer-data-container"

DATA_STORAGE_ID=$(az storage account show --name $DATA_STORAGE_ACCOUNT --query id -o tsv)

az role assignment create \
  --assignee $FORGE_API_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$DATA_STORAGE_ID/blobServices/default/containers/$DATA_CONTAINER"

az role assignment create \
  --assignee $SPARK_DRIVER_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$DATA_STORAGE_ID/blobServices/default/containers/$DATA_CONTAINER"
```

If the data is in a different storage account than what was provisioned in Step 6, also update forge-api:

```bash
kubectl set env deployment/forge-api -n forge AZURE_STORAGE_ACCOUNT=$DATA_STORAGE_ACCOUNT
```

## Step 13: Run Discovery

```bash
curl -s -H "Authorization: Bearer $API_KEY" \
  "http://localhost:6066/v1/discover?prefix=abfss://${DATA_CONTAINER}@${DATA_STORAGE_ACCOUNT}.dfs.core.windows.net/"
```

## Step 14: Run Crunch

```bash
curl -s -X POST http://localhost:6066/v1/submissions/create \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"mainClass\": \"com.granica.forge.ForgeOptimizer\",
    \"appResource\": \"local:///opt/spark/jars/crunch-spark-assembly-0.1.0.jar\",
    \"appArgs\": [\"--table-path\", \"abfss://${DATA_CONTAINER}@${DATA_STORAGE_ACCOUNT}.dfs.core.windows.net/path/to/parquet/\", \"--auto-learn\"],
    \"sparkProperties\": {\"spark.granica.enabled\": \"true\"}
  }"
```

## Step 15: Monitor

```bash
SID="driver-XXXXX"  # submissionId from Step 14

# Poll status
curl -s "http://localhost:6066/v1/submissions/status/$SID" -H "Authorization: Bearer $API_KEY"

# Watch pods
kubectl get pods -n forge -w

# Driver logs
kubectl logs -f -n forge -l spark-role=driver

# Crunch worker logs (executor sidecar)
kubectl logs -f -n forge -l spark-role=executor -c crunch-worker
```

States: `SUBMITTED` → `RUNNING` → `FINISHED` (success) or `FAILED`

---

## Teardown

To remove all resources:

```bash
# 1. Remove Helm releases
helm uninstall forge-api -n forge
helm uninstall spark-operator -n crunch
helm uninstall kube-prometheus-stack -n monitoring

# 2. Delete CRDs
kubectl delete crd forgejobs.forge.granica.ai forgemaintenancepolicies.forge.granica.ai 2>/dev/null

# 3. Delete AKS cluster
az aks delete --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --yes --no-wait

# 4. Delete remaining resources
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

---

## Reference: Resource Summary

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | `forge-<cluster>-rg` | Contains all resources |
| VNet | `<cluster>-vnet` (10.0.0.0/16) | Network isolation |
| Subnet | `aks-subnet` (10.0.0.0/20) | AKS nodes |
| NAT Gateway | `<cluster>-nat` | Predictable egress IP |
| AKS Cluster | `<cluster>` | Kubernetes control plane |
| System Pool | Standard_D2as_v7, 1-4 nodes | Platform services |
| Spark Driver Pool | Standard_F4as_v7, 0-4 nodes | Spark driver pods |
| Spark Executor Pool | Standard_F4as_v7, Spot, 0-8 | Spark executors |
| Evaluator Pool | Standard_F4as_v7, 0-2 nodes | Evaluation jobs |
| Storage Account | `forge<cluster><region>` | ADLS Gen2 (HNS) |
| System Container | `system` | Forge system data |
| forge-api MI | `<cluster>-forge-api` | API identity |
| spark-driver MI | `<cluster>-spark-driver` | Spark job identity |
| Federated Cred | `forge-api-sa` | K8s SA → MI trust |
| Federated Cred | `spark-driver-sa` | K8s SA → MI trust |
