# Image pins for Granica Forge release v0.0.0-alpha-citest1.
# Published in the public repo as terraform/forge-aws/granica-release-images.tfvars.
# Pair with your own -var-file for account-specific settings (optional: s3_bucket_arns if Forge should access S3).

forge_api_image = "763165855768.dkr.ecr.us-west-2.amazonaws.com/forge-api:v0.0.0-alpha-citest1"
crunch_image    = "763165855768.dkr.ecr.us-west-2.amazonaws.com/crunch:v0.0.0-alpha-citest1"
spark_image     = "763165855768.dkr.ecr.us-west-2.amazonaws.com/crunch:v0.0.0-alpha-citest1-spark"
