variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "forge"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC ID to deploy the cluster into. If empty, a new VPC is created."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Private subnet IDs for EKS nodes. If empty, new subnets are created."
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = <<-EOT
    Optional. S3 bucket ARNs the IRSA roles (forge-api, spark-driver) are allowed to read/write.
    Set this when Forge should access customer data or system data in S3; list bucket ARNs only
    (arn:aws:s3:::name) — object ARNs are derived. In 'customer' mode, omit or use [] if you do not
    need S3 access yet. In 'hosted' mode this is ignored — bucket policies on the customer side
    control access; the identity policy grants s3:* on Resource:* (TKT-020).
  EOT
  type    = list(string)
  default = []
}

variable "forge_api_image" {
  description = "forge-api container image URI. Must be pinned to a specific release tag (e.g. v0.3.0-rc), not :latest."
  type        = string
  # No default — forces explicit version at apply time.
  # Use: terraform apply -var="forge_api_image=809541265033.dkr.ecr.us-west-2.amazonaws.com/forge-api:v0.3.0-rc"
}

variable "spark_image" {
  description = "Spark container image URI (Granica inline writer). Must be pinned to a release tag."
  type        = string
  # No default — forces explicit version at apply time.
}

variable "crunch_image" {
  description = "crunch-worker sidecar image URI. Must be pinned to a release tag."
  type        = string
  # No default — forces explicit version at apply time.
}

variable "mode" {
  description = "Deployment mode: 'customer' (Mode A — deploy in customer account) or 'hosted' (Mode B — Granica account with cross-account S3)."
  type        = string
  default     = "customer"
  validation {
    condition     = contains(["customer", "hosted"], var.mode)
    error_message = "mode must be 'customer' or 'hosted'."
  }
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API server public endpoint. Restrict to known egress IPs for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Override in production tfvars
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "gitlab_project_path" {
  description = "GitLab project path prefix for OIDC trust (e.g. 'projectnn/ai-pilot'). Set to enable CI runner IAM role."
  type        = string
  default     = ""
}

variable "ci_s3_buckets" {
  description = "S3 bucket names the CI runner role can access (test data, sccache, etc.)"
  type        = list(string)
  default     = []
}

variable "enable_karpenter" {
  description = "Install Karpenter and apply NodePool manifests. Disable (default) when using managed node groups only."
  type        = bool
  default     = false
}

variable "enable_yunikorn" {
  description = "Install Apache YuniKorn batch scheduler. Not deployed on staging-ai-dev yet."
  type        = bool
  default     = false
}

variable "arch" {
  description = "CPU architecture for node scheduling: arm64 (Graviton) or amd64 (Intel/AMD). Must match the instance types in your node groups."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.arch)
    error_message = "arch must be 'arm64' or 'amd64'."
  }
}

variable "tracing_enabled" {
  description = <<-EOT
    Enable distributed tracing via AWS X-Ray (RFC-0066).
    When true, adds xray:PutTraceSegments and related permissions to the
    spark-driver IRSA role, and sets FORGE_TRACING_ENABLED=true on forge-api.
    Traces are exported to AWS X-Ray via OTLP/HTTP — no additional infrastructure needed.
    Disable to suppress all OTEL initialization on driver pods (zero overhead).
  EOT
  type    = bool
  default = true
}
