# Wait for the forge-api LoadBalancer to get an external hostname before outputting it.
data "kubernetes_service" "forge_api" {
  count      = var.enable_legacy_forge_api_release ? 1 : 0
  depends_on = [helm_release.forge_api]
  metadata {
    name      = "forge-api"
    namespace = "forge"
  }
}

locals {
  forge_lb_host = var.enable_legacy_forge_api_release ? try(
    data.kubernetes_service.forge_api[0].status.0.load_balancer.0.ingress.0.hostname,
    data.kubernetes_service.forge_api[0].status.0.load_balancer.0.ingress.0.ip,
    "pending"
  ) : null
}

output "forge_api_endpoint" {
  description = "spark-submit --master value: rest://<host>:6066 --deploy-mode cluster"
  value       = local.forge_lb_host != null ? "rest://${local.forge_lb_host}:6066" : null
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Run to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "spark_history_server_url" {
  description = "Spark job history UI"
  value       = "http://spark-history-server.forge.svc.cluster.local:18080"
}

output "deploy_mode" {
  value = var.mode
}

output "forge_api_role_arn" {
  description = "IAM role ARN annotated on the forge-api service account (created or pre-existing)"
  value       = local.forge_api_role_arn
}

output "spark_driver_role_arn" {
  description = "IAM role ARN annotated on the spark-driver service account (created or pre-existing)"
  value       = local.spark_driver_role_arn
}
