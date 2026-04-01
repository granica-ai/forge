# Image pins for Granica Forge release v0.6.21-alpha.
# Published in the public repo as terraform/forge-azure/granica-release-images.tfvars.
# Pair with your own -var-file for account-specific settings (subscription_id, storage_container_names).

forge_api_image = "granicaaz.azurecr.io/forge-api:v0.6.21-alpha"
crunch_image    = "granicaaz.azurecr.io/crunch:v0.6.21-alpha-azure4"
spark_image     = "granicaaz.azurecr.io/crunch:v0.6.21-alpha-spark"
