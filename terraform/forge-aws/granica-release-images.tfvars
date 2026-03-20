# Image pins for Granica Forge release v1.2.5.
# Published in the public repo as terraform/forge-aws/granica-release-images.tfvars.
# Pair with your own -var-file for account-specific settings (optional: s3_bucket_arns if Forge should access S3).

forge_api_image = "763165855768.dkr.ecr.us-west-2.amazonaws.com/forge-api:v1.2.5"
crunch_image    = "763165855768.dkr.ecr.us-west-2.amazonaws.com/crunch:v1.2.5"
spark_image     = "763165855768.dkr.ecr.us-west-2.amazonaws.com/crunch:v1.2.5-spark"
