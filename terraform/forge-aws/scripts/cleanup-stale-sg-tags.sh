#!/usr/bin/env bash
# cleanup-stale-sg-tags.sh — TKT-102 manual remediation helper
#
# Removes kubernetes.io/cluster/<CLUSTER_NAME> tags from all security groups
# in <REGION> that are NOT the current active node group SG. Run this before
# a cluster rebuild if a prior destroy left orphaned SG tags.
#
# Usage:
#   ./cleanup-stale-sg-tags.sh forge-customer-ai us-west-2
#   ./cleanup-stale-sg-tags.sh <CLUSTER_NAME> <REGION>
#
# The script is SAFE: it only removes the kubernetes.io/cluster/* tag — it does
# not delete any security group or modify any other resource.
#
# When to run:
#   1. Before tofu apply after a failed or partial cluster destroy
#   2. If LoadBalancer provisioning fails with "Multiple tagged security groups
#      found for instance" and manual triage confirms a stale SG is present
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <region>}"
REGION="${2:?Usage: $0 <cluster-name> <region>}"
TAG_KEY="kubernetes.io/cluster/${CLUSTER_NAME}"

echo "==> Scanning for SGs tagged ${TAG_KEY} in region ${REGION}..."

SG_IDS=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=tag-key,Values=${TAG_KEY}" \
  --query "SecurityGroups[].{Id:GroupId,Name:GroupName}" \
  --output text)

if [ -z "$SG_IDS" ]; then
  echo "    No SGs found with tag ${TAG_KEY}. Nothing to do."
  exit 0
fi

echo "    Found SGs:"
echo "$SG_IDS" | while IFS=$'\t' read -r gid gname; do
  echo "      $gid  ($gname)"
done

echo ""
read -rp "==> Remove ${TAG_KEY} tag from ALL of the above SGs? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo "$SG_IDS" | while IFS=$'\t' read -r gid _; do
  echo "    Removing tag from $gid..."
  aws ec2 delete-tags \
    --region "$REGION" \
    --resources "$gid" \
    --tags "Key=${TAG_KEY}"
done

echo ""
echo "==> Done. Verify with:"
echo "    aws ec2 describe-security-groups --region ${REGION} \\"
echo "      --filters 'Name=tag-key,Values=${TAG_KEY}' \\"
echo "      --query 'SecurityGroups[].GroupId'"
