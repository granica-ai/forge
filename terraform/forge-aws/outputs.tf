# Wait for the forge-api LoadBalancer to get an external hostname before outputting it.
data "kubernetes_service" "forge_api" {
  depends_on = [helm_release.forge_api]
  metadata {
    name      = "forge-api"
    namespace = "forge"
  }
}

locals {
  forge_lb_host = try(
    data.kubernetes_service.forge_api.status.0.load_balancer.0.ingress.0.hostname,
    data.kubernetes_service.forge_api.status.0.load_balancer.0.ingress.0.ip,
    "pending"
  )
}

output "forge_api_endpoint" {
  description = "spark-submit --master value: rest://<host>:6066 --deploy-mode cluster"
  value       = "rest://${local.forge_lb_host}:6066"
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
