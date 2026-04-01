# Deploy Forge on Azure — Manual Configuration

This guide explains how to deploy Forge on Azure using manually created resources. Use this method if you want full control over each Azure resource or need custom configurations.

This guide assumes you are running from **Azure Cloud Shell** (`shell.azure.com`).

## Prerequisites

- Azure subscription with Contributor access
- `kubectl` (pre-installed in Cloud Shell)
- `helm` (pre-installed in Cloud Shell)

## Overview

1. Set variables
2. Create Resource Group
3. Create Virtual Network + Subnet + NAT Gateway
4. Create AKS Cluster + Spot Node Pool
5. Create Image Pull Secret
6. Create Storage Account (ADLS Gen2)
7. Create Managed Identities + Federated Credentials
8. Grant Storage RBAC
9. Clone Forge repo + Install Helm Charts
10. Verify + Run Discovery + Crunch

---

## Step 1: Set variables

```bash
SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
REGION="eastus2"
CLUSTER_NAME="forge"
API_KEY="your-api-key"
ACR_NAME="granicaaz"

RESOURCE_GROUP="forge-${CLUSTER_NAME}-rg"
STORAGE_ACCOUNT="forge${CLUSTER_NAME//[-]/}${REGION//[-]/}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"
VNET_NAME="${CLUSTER_NAME}-vnet"
SUBNET_NAME="aks-subnet"

az account set --subscription $SUBSCRIPTION_ID
```

## Step 2: Create Resource Group

```bash
az group create --name $RESOURCE_GROUP --location $REGION --tags "forge.granica.ai-managed=true"
```

## Step 3: Create Virtual Network

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

### 4a. Create cluster with on-demand node pool

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

### 4b. Add Spot node pool

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name spot \
  --node-vm-size Standard_D2as_v7 \
  --node-count 0 \
  --min-count 0 \
  --max-count 8 \
  --enable-cluster-autoscaler \
  --node-osdisk-size 100 \
  --vnet-subnet-id $SUBNET_ID \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \
  --labels nodeUse=granica-on-spot \
  --node-taints "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
```

### 4c. Get cluster credentials

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --overwrite-existing

kubectl get nodes
```

## Step 5: Create Image Pull Secret

Create namespaces and add the ACR pull secret (credentials provided by Granica).

```bash
kubectl create namespace forge

kubectl create secret docker-registry forge-pull-secret \
  --namespace forge \
  --docker-server=${ACR_NAME}.azurecr.io \
  --docker-username=GRANICA_PROVIDED_USERNAME \
  --docker-password=GRANICA_PROVIDED_PASSWORD

kubectl create namespace crunch

kubectl create secret docker-registry forge-pull-secret \
  --namespace crunch \
  --docker-server=${ACR_NAME}.azurecr.io \
  --docker-username=GRANICA_PROVIDED_USERNAME \
  --docker-password=GRANICA_PROVIDED_PASSWORD
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

## Step 8: Grant Storage RBAC

```bash
STORAGE_ID=$(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)

az role assignment create \
  --assignee $FORGE_API_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID

az role assignment create \
  --assignee $SPARK_DRIVER_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $STORAGE_ID
```

## Step 9: Clone Forge repo + Install Helm Charts

### 9a. Clone Forge repo

```bash
git clone --depth 1 --branch azure-manual-guide https://github.com/granica-ai/forge.git /tmp/forge
```

### 9b. Spark Operator

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

### 9c. Prometheus + Grafana

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

### 9d. Apply CRDs + Create API Key Secret

```bash
kubectl apply -f /tmp/forge/k8s/forgejob-crd.yaml

kubectl create secret generic forge-api-keys \
  --namespace forge \
  --from-literal=keys="$API_KEY"
```

### 9e. Install forge-api

```bash
helm install forge-api /tmp/forge/helm/forge-api \
  --namespace forge \
  --set cloud=azure \
  --set "nodeSelector.kubernetes\.io/arch=amd64" \
  --set image.repository=granicaaz.azurecr.io/forge-api \
  --set image.tag=v0.6.21-alpha \
  --set "imagePullSecrets[0].name=forge-pull-secret" \
  --set env.FORGE_CLOUD_PROVIDER=azure \
  --set env.AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  --set env.AZURE_SPARK_CLIENT_ID=$SPARK_DRIVER_CLIENT_ID \
  --set env.FORGE_SPARK_IMAGE=granicaaz.azurecr.io/crunch:v0.6.21-alpha-spark \
  --set env.FORGE_CRUNCH_IMAGE=granicaaz.azurecr.io/crunch:v0.6.21-alpha-azure4 \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$FORGE_API_CLIENT_ID" \
  --set "sparkDriver.serviceAccount.annotations.azure\.workload\.identity/client-id=$SPARK_DRIVER_CLIENT_ID"
```

## Step 10: Verify + Run

### Health check

```bash
kubectl run health-check --rm -it --restart=Never --image=busybox -n forge -- sh -c "wget -qO- http://forge-api.forge.svc.cluster.local:6066/healthz"
```

Expected: `{"status":"ok"}`

### Discovery

Replace the `abfss://` path with your data location. The shell variables from Step 1 are used automatically.

```bash
kubectl run discovery --rm -it --restart=Never --image=busybox -n forge -- sh -c "wget -qO- 'http://forge-api.forge.svc.cluster.local:6066/v1/discover?prefix=abfss://testdata@${STORAGE_ACCOUNT}.dfs.core.windows.net/forge-qa/crunch-test/snappy_parquet/' --header='Authorization: Bearer ${API_KEY}'"
```

### Crunch

```bash
kubectl run crunch --rm -it --restart=Never --image=busybox -n forge -- sh -c "wget -qO- --post-data='{\"mainClass\":\"com.granica.forge.ForgeOptimizer\",\"appResource\":\"local:///opt/spark/jars/crunch-spark-assembly-0.1.0.jar\",\"appArgs\":[\"--table-path\",\"abfss://testdata@${STORAGE_ACCOUNT}.dfs.core.windows.net/forge-qa/crunch-test/snappy_parquet/\",\"--auto-learn\"],\"sparkProperties\":{\"spark.granica.enabled\":\"true\"}}' --header='Authorization: Bearer ${API_KEY}' --header='Content-Type: application/json' 'http://forge-api.forge.svc.cluster.local:6066/v1/submissions/create'"
```

### Monitor

```bash
# Check status (replace SUBMISSION_ID with the submissionId from the crunch response)
kubectl run status --rm -it --restart=Never --image=busybox -n forge -- sh -c "wget -qO- --header='Authorization: Bearer ${API_KEY}' 'http://forge-api.forge.svc.cluster.local:6066/v1/submissions/status/SUBMISSION_ID'"

# Watch pods
kubectl get pods -n forge -w

# Driver logs
kubectl logs -f -n forge -l spark-role=driver

# Crunch worker logs
kubectl logs -f -n forge -l spark-role=executor -c crunch-worker
```

---

## Teardown

```bash
helm uninstall forge-api -n forge
helm uninstall spark-operator -n crunch
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete crd forgejobs.forge.granica.ai 2>/dev/null
az aks delete --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --no-wait
az group delete --name $RESOURCE_GROUP --no-wait
```
