# Teardown

To destroy the Azure Forge deployment:

```bash
cd terraform/forge-azure

# 1. Remove Helm releases and CRDs first (prevents orphaned LBs).
az aks get-credentials --resource-group <rg> --name <cluster>
helm uninstall forge-api -n forge
helm uninstall spark-operator -n crunch
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete crd forgejobs.forge.granica.ai forgemaintenancepolicies.forge.granica.ai

# 2. Destroy Terraform-managed infrastructure.
terraform destroy -var-file=granica-release-images.tfvars -var="subscription_id=<sub-id>"

# 3. Verify resource group is deleted.
az group show --name <rg> 2>/dev/null && echo "WARNING: Resource group still exists" || echo "Clean."
```

If `terraform destroy` fails with a stuck load balancer, delete the forge-api Service first:

```bash
kubectl delete svc forge-api -n forge
# Then retry terraform destroy.
```
