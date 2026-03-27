# Wait for the forge-api LoadBalancer to get an external IP before outputting it.
data "kubernetes_service" "forge_api" {
  depends_on = [helm_release.forge_api]
  metadata {
    name      = "forge-api"
    namespace = "forge"
  }
}

locals {
  forge_lb_host = try(
    data.kubernetes_service.forge_api.status.0.load_balancer.0.ingress.0.ip,
    data.kubernetes_service.forge_api.status.0.load_balancer.0.ingress.0.hostname,
    "pending"
  )
}

output "forge_api_endpoint" {
  description = "spark-submit --master value: rest://<host>:6066 --deploy-mode cluster"
  value       = "rest://${local.forge_lb_host}:6066"
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.forge.name
}

output "kubeconfig_command" {
  description = "Run to configure kubectl"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.forge.name} --name ${var.cluster_name}"
}

output "spark_history_server_url" {
  description = "Spark job history UI"
  value       = "http://spark-history-server.forge.svc.cluster.local:18080"
}

output "deploy_mode" {
  value = var.mode
}

output "storage_account_name" {
  description = "Azure Storage Account name (use in abfs:// URIs)"
  value       = azurerm_storage_account.forge.name
}

output "resource_group_name" {
  value = azurerm_resource_group.forge.name
}
