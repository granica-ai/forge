terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.forge.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.forge.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.forge.kube_config[0].cluster_ca_certificate)
}

locals {
  resource_group_name  = var.resource_group_name != "" ? var.resource_group_name : "forge-${var.cluster_name}-rg"
  storage_account_name = var.storage_account_name != "" ? var.storage_account_name : substr(replace("forge${var.cluster_name}${var.region}", "-", ""), 0, 24)
  create_vnet          = var.vnet_id == ""
  vnet_id              = local.create_vnet ? azurerm_virtual_network.forge[0].id : var.vnet_id
  subnet_id            = local.create_vnet ? azurerm_subnet.aks[0].id : var.subnet_id

  # Azure tags cannot contain '/' — use dot-separated format instead of AWS-style path tags.
  common_tags = merge(var.tags, { "forge.granica.ai-managed" = "true" })
}

# ── Resource Group ────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "forge" {
  name     = local.resource_group_name
  location = var.region
  tags     = local.common_tags
}

# ── Optional VNet ─────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "forge" {
  count               = local.create_vnet ? 1 : 0
  name                = "${var.cluster_name}-vnet"
  location            = var.region
  resource_group_name = azurerm_resource_group.forge.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  count                = local.create_vnet ? 1 : 0
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.forge.name
  virtual_network_name = azurerm_virtual_network.forge[0].name
  address_prefixes     = ["10.0.0.0/20"]
}

resource "azurerm_nat_gateway" "forge" {
  count               = local.create_vnet ? 1 : 0
  name                = "${var.cluster_name}-nat"
  location            = var.region
  resource_group_name = azurerm_resource_group.forge.name
  sku_name            = "Standard"
  tags                = local.common_tags
}

resource "azurerm_public_ip" "nat" {
  count               = local.create_vnet ? 1 : 0
  name                = "${var.cluster_name}-nat-ip"
  location            = var.region
  resource_group_name = azurerm_resource_group.forge.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "forge" {
  count                = local.create_vnet ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.forge[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  count          = local.create_vnet ? 1 : 0
  subnet_id      = azurerm_subnet.aks[0].id
  nat_gateway_id = azurerm_nat_gateway.forge[0].id
}

# ── AKS Cluster ───────────────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "forge" {
  name                = var.cluster_name
  location            = var.region
  resource_group_name = azurerm_resource_group.forge.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = var.vm_size_system
    min_count            = 1
    max_count            = 4
    auto_scaling_enabled = true
    os_disk_size_gb      = 100
    vnet_subnet_id       = local.subnet_id
    node_labels = {
      "forge.granica.ai/pool" = "system"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.48.0.0/16"
    service_cidr        = "10.47.128.0/20"
    dns_service_ip      = "10.47.128.10"
    load_balancer_sku   = "standard"
    outbound_type       = local.create_vnet ? "userAssignedNATGateway" : "loadBalancer"
  }

  identity {
    type = "SystemAssigned"
  }

  storage_profile {
    disk_driver_enabled = true
    file_driver_enabled = true
  }

  tags = local.common_tags

  depends_on = [
    azurerm_subnet_nat_gateway_association.aks
  ]
}

# ── Node Pools ────────────────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster_node_pool" "spark_driver" {
  name                  = "sparkdriver"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.forge.id
  vm_size               = var.vm_size_spark_driver
  min_count             = 0
  max_count             = 4
  auto_scaling_enabled  = true
  os_disk_size_gb       = 100
  vnet_subnet_id        = local.subnet_id
  node_labels = {
    "forge.granica.ai/pool" = "spark-driver"
  }
}

# Multi-VM-family for Spot diversity — avoids capacity failure when
# a single family is unavailable. Uses eviction_policy = Delete and
# spot_max_price = -1 (pay up to on-demand price) for best availability.
resource "azurerm_kubernetes_cluster_node_pool" "spark_executor" {
  name                  = "sparkexec"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.forge.id
  vm_size               = var.vm_size_spark_executor
  min_count             = 0
  max_count             = 8
  auto_scaling_enabled  = true
  os_disk_size_gb       = 100
  vnet_subnet_id        = local.subnet_id
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  node_labels = {
    "forge.granica.ai/pool"                         = "spark-executor"
    "kubernetes.azure.com/scalesetpriority"         = "spot"
  }
  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "evaluator" {
  name                  = "evaluator"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.forge.id
  vm_size               = var.vm_size_spark_driver
  min_count             = 0
  max_count             = 2
  auto_scaling_enabled  = true
  os_disk_size_gb       = 100
  vnet_subnet_id        = local.subnet_id
  node_labels = {
    "forge.granica.ai/pool" = "evaluator"
  }
}

# ── Storage Account + Containers ──────────────────────────────────────────────

resource "azurerm_storage_account" "forge" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.forge.name
  location                        = var.region
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true # ADLS Gen2 — required for abfs:// scheme
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = local.common_tags
}

resource "azurerm_storage_container" "system" {
  name                  = "system"
  storage_account_id    = azurerm_storage_account.forge.id
  container_access_type = "private"
}

# ── Managed Identities ────────────────────────────────────────────────────────
# Azure Workload Identity is the equivalent of AWS IRSA.
# Each identity needs: (1) RBAC role assignment, (2) federated credential
# linking K8s SA → Managed Identity.

resource "azurerm_user_assigned_identity" "forge_api" {
  name                = "${var.cluster_name}-forge-api"
  resource_group_name = azurerm_resource_group.forge.name
  location            = var.region
  tags                = local.common_tags
}

resource "azurerm_user_assigned_identity" "spark_driver" {
  name                = "${var.cluster_name}-spark-driver"
  resource_group_name = azurerm_resource_group.forge.name
  location            = var.region
  tags                = local.common_tags
}

# ── Federated Identity Credentials ───────────────────────────────────────────
# Links K8s service accounts to Azure Managed Identities via the AKS OIDC issuer.

resource "azurerm_federated_identity_credential" "forge_api" {
  name                = "forge-api-sa"
  resource_group_name = azurerm_resource_group.forge.name
  parent_id           = azurerm_user_assigned_identity.forge_api.id
  issuer              = azurerm_kubernetes_cluster.forge.oidc_issuer_url
  subject             = "system:serviceaccount:forge:forge-api"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_federated_identity_credential" "spark_driver" {
  name                = "spark-driver-sa"
  resource_group_name = azurerm_resource_group.forge.name
  parent_id           = azurerm_user_assigned_identity.spark_driver.id
  issuer              = azurerm_kubernetes_cluster.forge.oidc_issuer_url
  subject             = "system:serviceaccount:forge:spark-driver"
  audience            = ["api://AzureADTokenExchange"]
}

# ── Storage RBAC ──────────────────────────────────────────────────────────────
# Storage access strategy differs by deployment mode (mirrors AWS TKT-020):
#
#   customer mode: RBAC scoped to specific containers in var.storage_container_names.
#   hosted mode:   RBAC at storage account level (customer controls access via
#                  their own storage account RBAC, not Forge's identity policy).

locals {
  # In customer mode, scope to declared containers. In hosted mode, scope to account.
  storage_scope_account = azurerm_storage_account.forge.id
  storage_scope_containers = [
    for name in var.storage_container_names :
    "${azurerm_storage_account.forge.id}/blobServices/default/containers/${name}"
  ]
  forge_api_storage_scopes = var.mode == "hosted" ? [local.storage_scope_account] : concat(
    [local.storage_scope_account], # ListBlob needs account scope
    local.storage_scope_containers
  )
  spark_storage_scopes = var.mode == "hosted" ? [local.storage_scope_account] : concat(
    [local.storage_scope_account],
    local.storage_scope_containers
  )
}

# forge-api: Storage Blob Data Contributor — read/write for discovery, history, metrics, system tables
resource "azurerm_role_assignment" "forge_api_storage" {
  count                = length(local.forge_api_storage_scopes)
  scope                = local.forge_api_storage_scopes[count.index]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.forge_api.principal_id
}

# spark-driver: Storage Blob Data Contributor — read/write customer data
resource "azurerm_role_assignment" "spark_driver_storage" {
  count                = length(local.spark_storage_scopes)
  scope                = local.spark_storage_scopes[count.index]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.spark_driver.principal_id
}

# System container — both identities always need access to the Forge system container.
resource "azurerm_role_assignment" "forge_api_system" {
  scope                = "${azurerm_storage_account.forge.id}/blobServices/default/containers/${azurerm_storage_container.system.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.forge_api.principal_id
}

resource "azurerm_role_assignment" "spark_driver_system" {
  scope                = "${azurerm_storage_account.forge.id}/blobServices/default/containers/${azurerm_storage_container.system.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.spark_driver.principal_id
}

# ── Helm Releases ─────────────────────────────────────────────────────────────

resource "helm_release" "spark_operator" {
  depends_on       = [azurerm_kubernetes_cluster.forge]
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = "2.4.0"
  namespace        = "crunch"
  create_namespace = true
  wait             = true

  set {
    name  = "webhook.enable"
    value = "true"
  }
  set {
    name  = "spark.jobNamespaces[0]"
    value = ""
  }
  set {
    name  = "controller.env[0].name"
    value = "JAVA_TOOL_OPTIONS"
  }
  set {
    name  = "controller.env[0].value"
    value = "-Dkubernetes.auth.tryKubeConfig=false"
  }
  set {
    name  = "spark.sparkConf[0].name"
    value = "spark.kubernetes.master"
  }
  set {
    name  = "spark.sparkConf[0].value"
    value = "k8s://https://kubernetes.default.svc:443"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on       = [azurerm_kubernetes_cluster.forge]
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "82.2.1"
  namespace        = "monitoring"
  create_namespace = true

  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}

resource "helm_release" "yunikorn" {
  count            = var.enable_yunikorn ? 1 : 0
  depends_on       = [azurerm_kubernetes_cluster.forge]
  name             = "yunikorn"
  repository       = "https://apache.github.io/yunikorn-release"
  chart            = "yunikorn"
  namespace        = "yunikorn"
  create_namespace = true
}

# ── ForgeJob CRD ──────────────────────────────────────────────────────────────

resource "null_resource" "forgejob_crd" {
  depends_on = [azurerm_kubernetes_cluster.forge]
  triggers   = { cluster_name = var.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      az aks get-credentials --resource-group ${azurerm_resource_group.forge.name} --name ${var.cluster_name} --overwrite-existing
      kubectl apply -f ${path.module}/../../k8s/forgejob-crd.yaml
    EOF
  }
}

# ── forge-api Helm Release ─────────────────────────────────────────────────────

resource "helm_release" "forge_api" {
  depends_on       = [helm_release.spark_operator, null_resource.forgejob_crd]
  name             = "forge-api"
  chart            = "${path.module}/../../helm/forge-api"
  namespace        = "forge"
  create_namespace = true
  wait             = false

  set {
    name  = "image.repository"
    value = split(":", var.forge_api_image)[0]
  }
  set {
    name  = "image.tag"
    value = try(split(":", var.forge_api_image)[1], "latest")
  }
  set {
    name  = "env.FORGE_SPARK_IMAGE"
    value = var.spark_image
  }
  set {
    name  = "env.FORGE_CRUNCH_IMAGE"
    value = var.crunch_image
  }
  set {
    name  = "env.FORGE_CLOUD_PROVIDER"
    value = "azure"
  }
  set {
    name  = "env.AZURE_STORAGE_ACCOUNT"
    value = azurerm_storage_account.forge.name
  }
  set {
    name  = "env.AZURE_SPARK_CLIENT_ID"
    value = azurerm_user_assigned_identity.spark_driver.client_id
  }
  set {
    name  = "cloud"
    value = "azure"
  }
  set {
    name  = "nodeSelector.kubernetes\\.io/arch"
    value = var.arch
  }
  set {
    name  = "serviceAccount.annotations.azure\\.workload\\.identity/client-id"
    value = azurerm_user_assigned_identity.forge_api.client_id
  }
}

# ── Workload Identity Annotations ────────────────────────────────────────────
# Applied after forge-api Helm release creates the service accounts.
# Azure Workload Identity requires BOTH an annotation (client-id) AND
# a label (azure.workload.identity/use: "true") — the label triggers
# the mutating webhook that injects the token volume.

resource "null_resource" "workload_identity_annotations" {
  depends_on = [helm_release.forge_api]
  triggers   = { cluster_name = var.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      kubectl annotate sa forge-api -n forge \
        azure.workload.identity/client-id=${azurerm_user_assigned_identity.forge_api.client_id} --overwrite
      kubectl label sa forge-api -n forge \
        azure.workload.identity/use=true --overwrite

      kubectl annotate sa spark-driver -n forge \
        azure.workload.identity/client-id=${azurerm_user_assigned_identity.spark_driver.client_id} --overwrite
      kubectl label sa spark-driver -n forge \
        azure.workload.identity/use=true --overwrite
    EOF
  }
}
