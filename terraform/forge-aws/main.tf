terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

provider "aws" {
  region = var.region
  default_tags { tags = merge(var.tags, { "forge.granica.ai/managed" = "true" }) }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

locals {
  # Use provided VPC/subnets or create new ones.
  create_vpc = var.vpc_id == ""
  vpc_id     = local.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  subnet_ids = local.create_vpc ? module.vpc[0].private_subnets : var.subnet_ids
}

# ── Optional VPC ───────────────────────────────────────────────────────────────

module "vpc" {
  count   = local.create_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["${var.region}a", "${var.region}b", "${var.region}c"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"      = "1"
    "karpenter.sh/discovery"               = var.cluster_name
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  vpc_id          = local.vpc_id
  subnet_ids      = local.subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs

  # EKS add-ons — managed by AWS, auto-upgraded with cluster version.
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # Managed node groups — matches deployed state on staging-ai-dev.
  # When Karpenter is installed, spark-driver/spark-executor/evaluator
  # migrate to Karpenter NodePools (see deploy/karpenter/nodepools.yaml).
  # The system group stays as a managed node group permanently.
  eks_managed_node_groups = {
    system = {
      instance_types = ["m8g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 4
      desired_size   = 1
      labels = {
        "forge.granica.ai/pool" = "system"
      }
    }

    spark-driver = {
      instance_types = ["m8g.xlarge"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = 0
      max_size       = 4
      desired_size   = 2
      labels = {
        "forge.granica.ai/pool" = "spark-driver"
      }
    }

    # Multi-instance-type for Spot diversity — avoids capacity failure when
    # a single instance type is unavailable. 5 types across m/c/r families.
    spark-executor = {
      instance_types = ["m8g.2xlarge", "c8g.2xlarge", "r8g.2xlarge", "m8g.4xlarge", "c8g.4xlarge"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 8
      desired_size   = 0
      labels = {
        "forge.granica.ai/pool" = "spark-executor"
      }
    }

    evaluator = {
      instance_types = ["m8g.2xlarge"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = 0
      max_size       = 2
      desired_size   = 0
      labels = {
        "forge.granica.ai/pool" = "evaluator"
      }
    }
  }

  # Karpenter needs permissions on the cluster.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# ── EBS CSI Driver IRSA ──────────────────────────────────────────────────────
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ── EKS Access Entry for deploying role (TF-001) ───────────────────────────────
# Without this, kubectl commands from the deploying IAM role fail post-cluster creation.
# The deploying role is the IAM entity running terraform apply (OrganizationAccountAccessRole
# in fresh accounts, or a dedicated CI role). We grant it cluster admin so deploy scripts
# can apply CRDs and Helm releases without a separate bootstrap step.
data "aws_caller_identity" "current" {}

# Resolve the STS assumed-role ARN to the underlying IAM role ARN.
# aws_caller_identity.arn returns arn:aws:sts::...:assumed-role/RoleName/session
# but EKS access entries require arn:aws:iam::...:role/... format.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_entry" "deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
  depends_on    = [module.eks]
}

resource "aws_eks_access_policy_association" "deployer_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on    = [aws_eks_access_entry.deployer]
}

# Karpenter node role — EC2 instances launched by Karpenter need an EKS access entry
# to register with the cluster. Without this, nodes launch but never become Ready.
resource "aws_eks_access_entry" "karpenter_node" {
  count         = var.enable_karpenter ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"
  depends_on    = [module.eks_blueprints_addons]
}

# ── IRSA Roles ─────────────────────────────────────────────────────────────────

# forge-api IRSA — S3 read/write for discovery, history, metrics, and system tables (TF-003)
resource "aws_iam_role" "forge_api" {
  name = "${var.cluster_name}-forge-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:forge*:forge-api"
        }
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# spark-driver IRSA — scoped to the customer's S3 buckets only
resource "aws_iam_role" "spark_driver" {
  name = "${var.cluster_name}-spark-driver"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:forge*:spark-driver"
        }
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# S3 access strategy differs by deployment mode (TKT-020):
#
#   customer mode (Mode A — Forge in customer account):
#     Identity policy scopes to explicit var.s3_bucket_arns. The customer's
#     IAM boundary controls what buckets are reachable.
#
#   hosted mode (Mode B — Forge in Granica account, cross-account S3):
#     Identity policy grants s3:* on Resource:* — the customer's S3 bucket
#     policy is the real access gate. Hardcoding bucket ARNs here doesn't
#     add security (bucket policies already enforce it) but creates friction:
#     every new customer bucket requires a Terraform re-apply. In hosted mode
#     Forge must be able to reach any bucket the customer allows via bucket
#     policy, including buckets unknown at deploy time. (TKT-012, TKT-020)

locals {
  # In hosted mode, use a broad Resource:* policy and rely on S3 bucket
  # policies. In customer mode, restrict to the declared bucket ARNs.
  forge_api_s3_resources = var.mode == "hosted" ? ["*"] : concat(
    var.s3_bucket_arns,
    [for arn in var.s3_bucket_arns : "${arn}/*"]
  )
  spark_s3_resources = var.mode == "hosted" ? ["*"] : concat(
    var.s3_bucket_arns,
    [for arn in var.s3_bucket_arns : "${arn}/*"]
  )
}

# forge-api S3 policy: read/write for discovery, history JSONL, metrics bridge, system tables (TF-003)
resource "aws_iam_role_policy" "forge_api_s3" {
  name = "forge-api-s3"
  role = aws_iam_role.forge_api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = local.forge_api_s3_resources
    }]
  })
}

# spark-driver S3 policy: read/write customer data (TF-003)
resource "aws_iam_role_policy" "spark_s3" {
  name = "spark-s3-access"
  role = aws_iam_role.spark_driver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = local.spark_s3_resources
    }]
  })
}

# spark-driver X-Ray policy: allows Connector to export OTLP traces to AWS X-Ray (RFC-0066).
# Only created when var.tracing_enabled = true (default).
# X-Ray is a native AWS service — no additional infrastructure needed.
# Disable with: terraform apply -var="tracing_enabled=false"
resource "aws_iam_role_policy" "spark_xray" {
  count = var.tracing_enabled ? 1 : 0
  name  = "spark-xray-trace-write"
  role  = aws_iam_role.spark_driver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets"
      ]
      Resource = "*"
    }]
  })
}

# ── EKS Blueprints Addons ──────────────────────────────────────────────────────

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_karpenter = var.enable_karpenter
  karpenter = {
    # v1.x required for karpenter.sh/v1 NodePool API (nodepools.yaml uses v1, not v1beta1)
    chart_version       = "1.3.3"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  helm_releases = merge(
    {
      spark-operator = {
        name             = "spark-operator"
        repository       = "https://kubeflow.github.io/spark-operator"
        chart            = "spark-operator"
        version          = "2.4.0"
        namespace        = "crunch"  # deployed to crunch namespace on staging-ai-dev
        create_namespace = true
        set = [
          { name = "webhook.enable",          value = "true" },
          # Watch all namespaces so CI pipelines can deploy to any namespace
          # (e.g. forge-dev, forge-dev-marc) without reconfiguring the operator.
          { name = "spark.jobNamespaces[0]",  value = "" },
          # TKT-078: fabric8 Vert.x in Spark 3.5.x "server null" on EKS.
          # Admission webhooks add ~10s to pod creation, racing with fabric8's default
          # 10s request timeout. Disabling kubeconfig detection forces in-cluster auth.
          { name = "controller.env[0].name",  value = "JAVA_TOOL_OPTIONS" },
          { name = "controller.env[0].value", value = "-Dkubernetes.auth.tryKubeConfig=false" },
          # HTTP2_DISABLE=true must be applied via kubectl set env post-deploy (not via Helm set{})
          # because Helm renders bare "true" as a YAML bool which K8s rejects on env.value (string field).
          # See: deploy/k8s/staging-ai-dev-post-deploy.sh for the kubectl set env command.
          # Explicit K8s master URL for spark-submit (belt-and-suspenders with env vars above)
          { name = "spark.sparkConf[0].name",  value = "spark.kubernetes.master" },
          { name = "spark.sparkConf[0].value", value = "k8s://https://kubernetes.default.svc:443" }
        ]
      }
      kube-prometheus-stack = {
        name             = "kube-prometheus-stack"
        repository       = "https://prometheus-community.github.io/helm-charts"
        chart            = "kube-prometheus-stack"
        version          = "82.2.1"
        namespace        = "monitoring"
        create_namespace = true
        set = [
          { name = "grafana.enabled", value = "true" },
          { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues", value = "false" }
        ]
      }
    },
    # YuniKorn — conditional, not deployed on staging-ai-dev yet.
    var.enable_yunikorn ? {
      yunikorn = {
        name             = "yunikorn"
        repository       = "https://apache.github.io/yunikorn-release"
        chart            = "yunikorn"
        namespace        = "yunikorn"
        create_namespace = true
      }
    } : {}
  )
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.us_east_1
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ── GitLab CI Runner IAM (optional, enabled when gitlab_project_path is set) ──

resource "aws_iam_openid_connect_provider" "gitlab" {
  count          = var.gitlab_project_path != "" ? 1 : 0
  url            = "https://gitlab.com"
  client_id_list = ["https://gitlab.com"]
  # GitLab OIDC thumbprint — stable, verified by AWS
  thumbprint_list = ["b826006e710c064b22e694936e834cbcf475e2b0"]
}

resource "aws_iam_role" "ci_runner" {
  count = var.gitlab_project_path != "" ? 1 : 0
  name  = "gitlab-ci-runner-staging"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.gitlab[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "gitlab.com:sub" = "project_path:${var.gitlab_project_path}/*:ref_type:branch:ref:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci_runner_s3" {
  count = var.gitlab_project_path != "" ? 1 : 0
  name  = "forge-ci-staging"
  role  = aws_iam_role.ci_runner[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ForgeStaging"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:GetObjectTagging", "s3:PutObject",
          "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"
        ]
        Resource = flatten([for b in var.ci_s3_buckets : [
          "arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"
        ]])
      },
      {
        Sid      = "EKSAccess"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = module.eks.cluster_arn
      },
      {
        Sid      = "ECRRead"
        Effect   = "Allow"
        Action   = [
          "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability", "ecr:GetAuthorizationToken",
          "ecr:DescribeRepositories", "ecr:ListImages", "ecr:DescribeImages"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_access_entry" "ci_runner" {
  count         = var.gitlab_project_path != "" ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.ci_runner[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_runner_admin" {
  count         = var.gitlab_project_path != "" ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.ci_runner[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on    = [aws_eks_access_entry.ci_runner]
}

# ── Karpenter NodePools ────────────────────────────────────────────────────────
# Applied via kubectl after cluster is ready (nodepools.yaml in deploy/karpenter/).
# Only created when Karpenter is enabled (var.enable_karpenter = true).
resource "null_resource" "karpenter_nodepools" {
  count      = var.enable_karpenter ? 1 : 0
  depends_on = [module.eks_blueprints_addons]
  triggers = { cluster_name = var.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region}
      # Wait for Karpenter CRDs to register with the API server
      echo "Waiting for Karpenter CRDs..."
      for i in $(seq 1 30); do
        if kubectl get crd nodepools.karpenter.sh &>/dev/null; then
          echo "Karpenter CRDs ready"
          break
        fi
        echo "  attempt $i/30..."
        sleep 5
      done
      # Substitute cluster name and Karpenter instance profile into the manifest.
      export CLUSTER_NAME="${var.cluster_name}"
      export KARPENTER_NODE_INSTANCE_PROFILE="${module.eks_blueprints_addons.karpenter.node_instance_profile_name}"
      envsubst < ${path.module}/../../karpenter/nodepools.yaml | kubectl apply -f -
      kubectl apply -f ${path.module}/../../k8s/forgejob-crd.yaml
    EOF
  }
}

# ── Stale Node SG Tag Cleanup (TKT-102) ──────────────────────────────────────
# When the cluster is destroyed, Terraform deletes the managed node group but
# does not always remove the kubernetes.io/cluster/<name> tag from the node
# group's security group before it is fully deleted (race condition). If the SG
# survives (e.g. due to a failed destroy), a subsequent cluster rebuild will find
# two SGs matching the tag selector and ELB provisioning will fail with
# "Multiple tagged security groups found for instance".
#
# This resource removes the offending tag from ALL SGs in the VPC that carry
# kubernetes.io/cluster/<cluster-name> at two times:
#   • during `destroy` (when = destroy): runs before the EKS module is torn down
#   • during `apply`  (when = create):  cleans up any SGs left over from a prior
#     failed destroy so the new cluster does not inherit stale tags
#
# The resource does NOT delete any SGs — only removes the single K8s tag.
resource "null_resource" "cleanup_node_sg_tags" {
  depends_on = [module.eks]
  triggers = { cluster_name = var.cluster_name, region = var.region }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      CLUSTER="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      echo "[TKT-102] Removing kubernetes.io/cluster/$CLUSTER tags from all SGs in $REGION..."
      SG_IDS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
        --query "SecurityGroups[].GroupId" \
        --output text)
      for sg_id in $SG_IDS; do
        echo "  Removing tag from SG: $sg_id"
        aws ec2 delete-tags \
          --region "$REGION" \
          --resources "$sg_id" \
          --tags "Key=kubernetes.io/cluster/$CLUSTER"
      done
      echo "[TKT-102] Done."
    EOF
  }

  provisioner "local-exec" {
    when        = create
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      CLUSTER="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      CURRENT_SG=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
        --query "SecurityGroups | sort_by(@, &Tags[?Key=='aws:cloudformation:stack-name'] | [0].Value || @.GroupName) | [-1].GroupId" \
        --output text 2>/dev/null || true)
      ALL_SG_IDS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
        --query "SecurityGroups[].GroupId" \
        --output text)
      CLEANED=0
      for sg_id in $ALL_SG_IDS; do
        if [ "$sg_id" != "$CURRENT_SG" ]; then
          echo "[TKT-102] Removing stale tag from orphaned SG: $sg_id"
          aws ec2 delete-tags \
            --region "$REGION" \
            --resources "$sg_id" \
            --tags "Key=kubernetes.io/cluster/$CLUSTER"
          CLEANED=$((CLEANED + 1))
        fi
      done
      echo "[TKT-102] Pre-apply cleanup complete. Removed tag from $CLEANED orphaned SG(s)."
    EOF
  }
}

# ── ForgJob CRD (always applied, independent of Karpenter) ──────────────────
resource "null_resource" "forgejob_crd" {
  count      = var.enable_karpenter ? 0 : 1  # only when Karpenter is disabled (Karpenter path applies it above)
  depends_on = [module.eks_blueprints_addons]
  triggers = { cluster_name = var.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region}
      kubectl apply -f ${path.module}/../../k8s/forgejob-crd.yaml
    EOF
  }
}

# ── forge-api Helm Release ─────────────────────────────────────────────────────
resource "helm_release" "forge_api" {
  depends_on = [module.eks_blueprints_addons]
  name       = "forge-api"
  chart      = "${path.module}/../../helm/forge-api"
  namespace  = "forge"
  create_namespace = true
  wait       = false

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
}

# ── IRSA Annotations ──────────────────────────────────────────────────────────
# Applied after forge-api Helm release creates the service accounts.
resource "null_resource" "irsa_annotations" {
  depends_on = [helm_release.forge_api]
  triggers = { cluster_name = var.cluster_name }
  provisioner "local-exec" {
    command = <<-EOF
      set -e
      kubectl annotate sa forge-api -n forge \
        eks.amazonaws.com/role-arn=${aws_iam_role.forge_api.arn} --overwrite
      kubectl annotate sa spark-driver -n forge \
        eks.amazonaws.com/role-arn=${aws_iam_role.spark_driver.arn} --overwrite
    EOF
  }
}
