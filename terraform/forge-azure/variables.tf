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
  description = "Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
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
    Optional. Storage container names the Managed Identities (forge-api, spark-driver)
    are allowed to read/write. In 'customer' mode, RBAC roles are scoped to these containers.
    In 'hosted' mode this is ignored — RBAC is granted at the storage account level.
  EOT
  type    = list(string)
  default = []
}

variable "forge_api_image" {
  description = "forge-api container image URI. Must be pinned to a specific release tag."
  type        = string
}

variable "spark_image" {
  description = "Spark container image URI (Granica inline writer). Must be pinned to a release tag."
  type        = string
}

variable "crunch_image" {
  description = "crunch-worker sidecar image URI. Must be pinned to a release tag."
  type        = string
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
  description = <<-EOT
    Enable distributed tracing via Azure Monitor / OTLP.
    When true, sets FORGE_TRACING_ENABLED=true on forge-api.
  EOT
  type    = bool
  default = true
}

variable "arch" {
  description = "CPU architecture for node scheduling: amd64 (Intel/AMD) or arm64 (Ampere). Must match the VM sizes in your node pools."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["arm64", "amd64"], var.arch)
    error_message = "arch must be 'arm64' or 'amd64'."
  }
}

variable "acr_id" {
  description = "Azure Container Registry resource ID. When set, grants AcrPull to the AKS kubelet identity so nodes can pull images."
  type        = string
  default     = ""
}

variable "api_key" {
  description = "API key for forge-api authentication. Creates the forge-api-keys K8s secret automatically."
  type        = string
  sensitive   = true
}

variable "vm_size_system" {
  description = "VM size for system node pool"
  type        = string
  default     = "Standard_D2as_v7"
}

variable "vm_size_spark_driver" {
  description = "VM size for spark-driver node pool"
  type        = string
  default     = "Standard_F4as_v7"
}

variable "vm_size_spark_executor" {
  description = "VM size for spark-executor (spot) node pool"
  type        = string
  default     = "Standard_F4as_v7"
}
