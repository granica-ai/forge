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
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id is optional — if empty, provider falls back to az CLI /
  # ARM_SUBSCRIPTION_ID. Customers deploying into a single subscription rarely
  # need to set this.
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
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
  resource_group_name  = var.resource_group_name != "" ? var.resource_group_name : "granica-${var.cluster_name}-rg"
  storage_account_name = var.storage_account_name != "" ? var.storage_account_name : substr(replace("forge${var.cluster_name}${var.region}", "-", ""), 0, 24)
  create_vnet          = var.vnet_id == ""
  vnet_id              = local.create_vnet ? azurerm_virtual_network.forge[0].id : var.vnet_id
  subnet_id            = local.create_vnet ? azurerm_subnet.aks[0].id : var.subnet_id

  common_tags = merge(var.tags, { "forge.granica.ai-managed" = "true" })

  forge_api_chart_path = var.forge_api_chart_path != "" ? var.forge_api_chart_path : "${path.module}/../../helm/forge-api"
  forgejob_crd_path    = var.forgejob_crd_path != "" ? var.forgejob_crd_path : "${path.module}/../../k8s/forgejob-crd.yaml"

  # Single image_repository + image_tag drive all three Forge images.
  # Registry layout (both clouds): <repo>/forge-api:<tag>, <repo>/crunch:<tag>, <repo>/crunch:<tag>-spark
  # image_tag defaults to "<release_version>-<arch>" when not explicitly set.
  image_tag       = var.image_tag != "" ? var.image_tag : "${var.release_version}-${var.arch}"
  forge_api_image = "${var.image_repository}/forge-api:${local.image_tag}"
  crunch_image    = "${var.image_repository}/crunch:${local.image_tag}"
  spark_image     = "${var.image_repository}/crunch:${local.image_tag}-spark"

  # api_key: use customer-provided value, or fall back to auto-generated one.
  api_key = var.api_key != "" ? var.api_key : random_password.api_key[0].result
}

# Generate a random 32-char key when the customer doesn't supply one.
# override_special drops quotes, backslash, backtick, and '$' to avoid
# shell-escaping surprises when the key is used in curl Authorization headers.
resource "random_password" "api_key" {
  count            = var.api_key == "" ? 1 : 0
  length           = 32
  special          = true
  override_special = "!@#%&*()-_=+[]{}<>:?/"
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
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  count                = local.create_vnet ? 1 : 0
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.forge.name
  virtual_network_name = azurerm_virtual_network.forge[0].name
  address_prefixes     = [var.aks_subnet_cidr]
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
# Two node pools only, mirroring the AWS Karpenter design:
#   default (granica-on-demand)  — system + forge-api + spark drivers
#   spotexec (granica-on-spot)   — spark executors
# AKS requires a default "system" pool for kube-system, so the default pool
# doubles as granica-on-demand.

resource "azurerm_kubernetes_cluster" "forge" {
  name                = var.cluster_name
  location            = var.region
  resource_group_name = azurerm_resource_group.forge.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "ondemand"
    vm_size              = var.vm_size_on_demand
    min_count            = 1
    max_count            = var.on_demand_pool_max_count
    auto_scaling_enabled = true
    os_disk_size_gb      = 100
    vnet_subnet_id       = local.subnet_id
    # nodeUse=granica-on-demand matches the AWS NodePool label used by the
    # forge-api Helm chart for nodeSelector on the forge-api + driver pods.
    node_labels = {
      "nodeUse" = "granica-on-demand"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
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

# ── Forge namespace ───────────────────────────────────────────────────────────
# Created explicitly (not via helm create_namespace) so the forge-api-keys
# and forge-pull-secret resources can be applied before the Helm release
# attempts to spin up forge-api pods that mount both secrets.

resource "kubernetes_namespace" "forge" {
  metadata {
    name = var.forge_namespace
  }
  depends_on = [azurerm_kubernetes_cluster.forge]
}

# ── ACR Image Pull Secret ─────────────────────────────────────────────────────
# Creates forge-pull-secret in both forge and spark-operator namespaces
# (matches manual deployment flow). AcrPull-on-kubelet-identity is a future
# simplification — tracked as a follow-up MR since it requires either
# customer-owned ACR or a two-step role-assignment handshake across subscriptions.

resource "kubernetes_secret" "forge_pull_secret" {
  metadata {
    name      = var.image_pull_secret_name
    namespace = kubernetes_namespace.forge.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.image_repository) = {
          username = var.image_pull_secret_username
          password = var.image_pull_secret_password
          auth     = base64encode("${var.image_pull_secret_username}:${var.image_pull_secret_password}")
        }
      }
    })
  }
}

resource "kubernetes_secret" "spark_pull_secret" {
  metadata {
    name      = var.image_pull_secret_name
    namespace = var.spark_operator_namespace
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.image_repository) = {
          username = var.image_pull_secret_username
          password = var.image_pull_secret_password
          auth     = base64encode("${var.image_pull_secret_username}:${var.image_pull_secret_password}")
        }
      }
    })
  }
  depends_on = [helm_release.spark_operator]
}

# ── API Key Secret ────────────────────────────────────────────────────────────
# Created before helm_release.forge_api so the Deployment can mount it
# immediately. The chart's apiKeys.secretName="forge-api-keys" default
# matches.

resource "kubernetes_secret" "forge_api_keys" {
  metadata {
    name      = "forge-api-keys"
    namespace = kubernetes_namespace.forge.metadata[0].name
  }
  data = {
    keys = local.api_key
  }
}

# ── Spot (granica-on-spot) Node Pool ──────────────────────────────────────────
# Scales with FORGE_MAX_CONCURRENT_JOBS × executors-per-job. min_count=0 so
# the pool scales fully to zero between jobs. eviction_policy=Delete +
# spot_max_price=-1 (pay up to on-demand) prioritises availability.

resource "azurerm_kubernetes_cluster_node_pool" "on_spot" {
  name                  = "onspot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.forge.id
  vm_size               = var.vm_size_on_spot
  min_count             = 0
  max_count             = var.on_spot_pool_max_count
  auto_scaling_enabled  = true
  os_disk_size_gb       = 100
  vnet_subnet_id        = local.subnet_id
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  node_labels = {
    "nodeUse"                               = "granica-on-spot"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }
  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]
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

# ── Managed Identity (single, shared by forge-api and spark-driver) ───────────
# AWS currently uses two IAM roles for forge-api and spark-driver, but both
# are granted the same S3 policies in practice. On Azure we consolidate to
# a single Workload Identity — fewer resources, simpler RBAC, same capability.
# A separate MR will mirror this consolidation on the AWS side.

resource "azurerm_user_assigned_identity" "forge" {
  name                = "${var.cluster_name}-forge"
  resource_group_name = azurerm_resource_group.forge.name
  location            = var.region
  tags                = local.common_tags
}

# Federated credentials — one per K8s ServiceAccount, both pointing at the
# same Managed Identity.

resource "azurerm_federated_identity_credential" "forge_api" {
  name                = "forge-api-sa"
  resource_group_name = azurerm_resource_group.forge.name
  parent_id           = azurerm_user_assigned_identity.forge.id
  issuer              = azurerm_kubernetes_cluster.forge.oidc_issuer_url
  subject             = "system:serviceaccount:${var.forge_namespace}:forge-api"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_federated_identity_credential" "spark_driver" {
  name                = "spark-driver-sa"
  resource_group_name = azurerm_resource_group.forge.name
  parent_id           = azurerm_user_assigned_identity.forge.id
  issuer              = azurerm_kubernetes_cluster.forge.oidc_issuer_url
  subject             = "system:serviceaccount:${var.forge_namespace}:spark-driver"
  audience            = ["api://AzureADTokenExchange"]
}

# ── Storage RBAC ──────────────────────────────────────────────────────────────
# Storage access differs by deployment mode (mirrors AWS TKT-020):
#   customer mode: RBAC scoped to containers in var.storage_container_names.
#   hosted mode:   RBAC at storage account level.

locals {
  storage_scope_account = azurerm_storage_account.forge.id
  storage_scope_containers = [
    for name in var.storage_container_names :
    "${azurerm_storage_account.forge.id}/blobServices/default/containers/${name}"
  ]
  # ListBlob needs account scope even in customer mode.
  forge_storage_scopes = var.mode == "hosted" ? [local.storage_scope_account] : concat(
    [local.storage_scope_account],
    local.storage_scope_containers
  )
}

resource "azurerm_role_assignment" "forge_storage" {
  count                = length(local.forge_storage_scopes)
  scope                = local.forge_storage_scopes[count.index]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.forge.principal_id
}

resource "azurerm_role_assignment" "forge_system_container" {
  scope                = "${azurerm_storage_account.forge.id}/blobServices/default/containers/${azurerm_storage_container.system.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.forge.principal_id
}

# ── Helm Releases ─────────────────────────────────────────────────────────────

resource "helm_release" "spark_operator" {
  depends_on       = [azurerm_kubernetes_cluster.forge]
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = var.spark_operator_chart_version
  namespace        = var.spark_operator_namespace
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
  version          = var.kube_prometheus_stack_chart_version
  namespace        = var.monitoring_namespace
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
  namespace        = var.yunikorn_namespace
  create_namespace = true
}

# ── ForgeJob CRD ──────────────────────────────────────────────────────────────
# Applied via local-exec because kubernetes_manifest cannot apply a CRD and a
# resource that uses it in the same Terraform apply. Kubeconfig is written
# from cluster output, so no external az/kubectl config is required.

resource "local_sensitive_file" "kubeconfig" {
  content  = azurerm_kubernetes_cluster.forge.kube_config_raw
  filename = "${path.module}/.kubeconfig-${var.cluster_name}"
}

resource "null_resource" "forgejob_crd" {
  depends_on = [azurerm_kubernetes_cluster.forge, local_sensitive_file.kubeconfig]
  triggers = {
    cluster_name = var.cluster_name
    crd_sha256   = filesha256(local.forgejob_crd_path)
  }
  provisioner "local-exec" {
    command     = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename} apply -f ${local.forgejob_crd_path}"
    interpreter = ["bash", "-c"]
  }
}

# ── forge-api Helm Release ─────────────────────────────────────────────────────
# Workload Identity labels + SA annotations are rendered by the Helm chart
# when cloud=azure — no post-apply kubectl annotate/label needed.

resource "helm_release" "forge_api" {
  # Depend on both Helm stacks because the chart renders a ServiceMonitor in
  # the monitoring namespace (needs kube_prometheus_stack's CRD + ns) and
  # submits SparkApplications via the Spark Operator. forge-api-keys and
  # forge-pull-secret must exist before the pod starts so volume mounts and
  # image pulls succeed immediately.
  depends_on = [
    helm_release.spark_operator,
    helm_release.kube_prometheus_stack,
    null_resource.forgejob_crd,
    kubernetes_namespace.forge,
    kubernetes_secret.forge_api_keys,
    kubernetes_secret.forge_pull_secret,
  ]
  name             = "forge-api"
  chart            = local.forge_api_chart_path
  namespace        = kubernetes_namespace.forge.metadata[0].name
  create_namespace = false
  wait             = false

  # Pass complex JSON env vars through a rendered values YAML — Helm's
  # --set can't carry JSON (mangles curly braces and splits on commas).
  values = [yamlencode({
    cloud         = "azure"
    forgeImageTag = local.image_tag
    # System data bucket — the chart auto-derives FORGE_HISTORY_BUCKET,
    # FORGE_METRICS_BASE_URI and FORGE_SYSTEM_TABLE_URI from this.
    dataBucket = "abfss://system@${azurerm_storage_account.forge.name}.dfs.core.windows.net"
    image = {
      repository = "${var.image_repository}/forge-api"
      tag        = local.image_tag
    }
    imagePullSecrets = [{ name = var.image_pull_secret_name }]
    nodeSelector = {
      "kubernetes.io/arch" = var.arch
      "nodeUse"            = "granica-on-demand"
    }
    serviceAccount = {
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.forge.client_id
      }
    }
    sparkDriver = {
      serviceAccount = {
        annotations = {
          "azure.workload.identity/client-id" = azurerm_user_assigned_identity.forge.client_id
        }
      }
    }
    env = {
      FORGE_CLOUD_PROVIDER  = "azure"
      FORGE_NAMESPACE       = var.forge_namespace
      FORGE_SPARK_IMAGE     = local.spark_image
      FORGE_CRUNCH_IMAGE    = local.crunch_image
      AZURE_STORAGE_ACCOUNT = azurerm_storage_account.forge.name
      AZURE_SPARK_CLIENT_ID = azurerm_user_assigned_identity.forge.client_id
      # Executors land on the spot pool; pass the Azure spot taint
      # tolerance through as JSON. chart-side just forwards the string
      # to the SparkApplication spec.
      FORGE_NODE_SELECTOR          = jsonencode({ nodeUse = "granica-on-demand" })
      FORGE_EXECUTOR_NODE_SELECTOR = jsonencode({ nodeUse = "granica-on-spot" })
      FORGE_EXECUTOR_TOLERATIONS = jsonencode([{
        key      = "kubernetes.azure.com/scalesetpriority"
        operator = "Equal"
        value    = "spot"
        effect   = "NoSchedule"
      }])
    }
  })]
}

# ── (forge_api_keys moved above helm_release so the pod mounts it immediately) ─
