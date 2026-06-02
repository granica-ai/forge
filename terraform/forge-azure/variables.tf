variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "forge"
}

variable "region" {
  description = "Azure region (e.g. eastus2, westus2)"
  type        = string
  default     = "eastus2"
}

variable "kubernetes_version" {
  description = "Kubernetes version (endoflife.date/azure-kubernetes-service)"
  type        = string
  default     = "1.34"
}

variable "subscription_id" {
  description = "Azure subscription ID. If empty, the provider uses the current az CLI subscription (or ARM_SUBSCRIPTION_ID)."
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Resource group name. If empty, one is created as forge-<cluster_name>-rg."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = "Existing VNet ID. If empty, a new VNet is created."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Existing subnet ID for AKS nodes. If empty, new subnets are created."
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "CIDR address space for the VNet when created by this module."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "aks_subnet_cidr" {
  description = "CIDR for the AKS subnet when created by this module."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pod_cidr" {
  description = "CIDR for pod IPs (Azure CNI Overlay). Must not overlap VNet or service CIDR."
  type        = string
  default     = "10.48.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes service IPs. Must not overlap VNet or pod CIDR."
  type        = string
  default     = "10.47.128.0/20"
}

variable "dns_service_ip" {
  description = "DNS service IP. Must be inside service_cidr (typically x.x.x.10)."
  type        = string
  default     = "10.47.128.10"
}

variable "storage_account_name" {
  description = <<-EOT
    Azure Storage Account name. Must be globally unique, 3-24 lowercase alphanumeric characters.
    If empty, one is created as forge<cluster_name><region> (truncated to 24 chars).
  EOT
  type        = string
  default     = ""
}

variable "storage_container_names" {
  description = <<-EOT
    Optional. Storage containers the Forge Managed Identity is allowed to read/write.
    In 'customer' mode, RBAC roles are scoped to these containers.
    In 'hosted' mode this is ignored — RBAC is granted at the storage account level.
  EOT
  type        = list(string)
  default     = []
}

variable "image_repository" {
  description = <<-EOT
    Container registry (without image name). Images are resolved as:
      forge-api: <image_repository>/forge-api:<image_tag>
      crunch:    <image_repository>/crunch:<image_tag>
      spark:     <image_repository>/crunch:<image_tag>-spark
  EOT
  type        = string
  default     = "granicaaz.azurecr.io"
}

variable "release_version" {
  description = <<-EOT
    Granica Forge release tag (e.g. "v0.8.3-alpha"). Templated to v1.0.0-rc1
    at publish time. The module derives image_tag as "<release_version>-<arch>"
    when image_tag is left blank.
  EOT
  type        = string
  default     = "v1.0.0-rc1"
}

variable "image_tag" {
  description = <<-EOT
    Full image tag. Optional — when empty the module derives it from
    release_version + arch (e.g. v0.8.3-alpha-amd64). Override only if you need
    a custom tag layout.
  EOT
  type        = string
  default     = ""
}

variable "mode" {
  description = "Deployment mode: 'customer' (Forge in customer subscription) or 'hosted' (Granica subscription, cross-tenant storage)."
  type        = string
  default     = "customer"
  validation {
    condition     = contains(["customer", "hosted"], var.mode)
    error_message = "mode must be 'customer' or 'hosted'."
  }
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "enable_yunikorn" {
  description = "Install Apache YuniKorn batch scheduler."
  type        = bool
  default     = false
}

variable "tracing_enabled" {
  description = "Enable distributed tracing (sets FORGE_TRACING_ENABLED on forge-api)."
  type        = bool
  default     = true
}

variable "arch" {
  description = "CPU architecture for node scheduling: amd64 or arm64. Must match the VM sizes."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["arm64", "amd64"], var.arch)
    error_message = "arch must be 'arm64' or 'amd64'."
  }
}

variable "image_pull_secret_name" {
  description = "Name of the Kubernetes docker-registry secret the module creates for pulling Forge images."
  type        = string
  default     = "forge-pull-secret"
}

variable "image_pull_secret_username" {
  description = "Username for the private container registry. Required."
  type        = string
  sensitive   = true
}

variable "image_pull_secret_password" {
  description = "Password/token for the private container registry. Required."
  type        = string
  sensitive   = true
}

variable "api_key" {
  description = <<-EOT
    API key for forge-api authentication. If left empty (default), a 32-char
    random string (letters + digits + safe special chars) is generated and
    surfaced as the sensitive 'api_key' Terraform output. Override only if
    you need to reuse an existing key.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# ── VM sizes ─────────────────────────────────────────────────────────────────

variable "vm_size_on_demand" {
  description = "VM size for the granica-on-demand node pool (system + forge-api + spark drivers). Default matches the manual deployment doc."
  type        = string
  default     = "Standard_D4as_v7"
}

variable "vm_size_on_spot" {
  description = "VM size for the granica-on-spot node pool (spark executors). Default matches the manual deployment doc — fits 2 executors per node."
  type        = string
  default     = "Standard_D8as_v7"
}

# ── Pool max counts ──────────────────────────────────────────────────────────
# Both pools scale with FORGE_MAX_CONCURRENT_JOBS × resources-per-job:
#   on-demand: 1 driver pod per concurrent job, plus forge-api + operators.
#   on-spot:   N executor pods per concurrent job (default 1-2 per driver).

variable "on_demand_pool_max_count" {
  description = "Max node count for the granica-on-demand pool autoscaling."
  type        = number
  default     = 4
}

variable "on_spot_pool_max_count" {
  description = "Max node count for the granica-on-spot pool autoscaling. Default matches the manual deployment doc."
  type        = number
  default     = 100
}

# ── Helm chart versions ──────────────────────────────────────────────────────

variable "spark_operator_chart_version" {
  description = "spark-operator Helm chart version."
  type        = string
  default     = "2.5.0"
}

variable "kube_prometheus_stack_chart_version" {
  description = "kube-prometheus-stack Helm chart version."
  type        = string
  default     = "82.2.1"
}

# ── Chart + CRD paths ────────────────────────────────────────────────────────
# Default to in-repo paths. Customer deployments using artifacts from
# granica-ai/forge should override these to point at the local artifact copy.

variable "forge_api_chart_path" {
  description = "Path to the forge-api Helm chart. Defaults to the in-repo copy."
  type        = string
  default     = ""
}

variable "forgejob_crd_path" {
  description = "Path to the ForgeJob CRD manifest. Defaults to the in-repo copy."
  type        = string
  default     = ""
}

# ── Namespaces ───────────────────────────────────────────────────────────────

variable "forge_namespace" {
  description = "Kubernetes namespace for forge-api."
  type        = string
  default     = "forge"
}

variable "spark_operator_namespace" {
  description = "Kubernetes namespace for spark-operator"
  type        = string
  default     = "spark-operator"
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for kube-prometheus-stack."
  type        = string
  default     = "monitoring"
}

variable "yunikorn_namespace" {
  description = "Kubernetes namespace for YuniKorn."
  type        = string
  default     = "yunikorn"
}
