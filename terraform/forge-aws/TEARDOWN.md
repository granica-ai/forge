# Cluster Teardown Runbook

> **Read this before running `tofu destroy`.**
> Skipping the pre-destroy steps can leave orphaned AWS resources that block
> a future cluster rebuild (TKT-102).

---

## Pre-destroy checklist

Run the following steps *before* `tofu destroy`:

### 1. Audit node security group tags (TKT-102)

The EKS node group SG carries a `kubernetes.io/cluster/<name>` tag. If a
previous destroy left a stale SG with the same tag, a fresh cluster rebuild
will fail to provision LoadBalancer services with:

```
SyncLoadBalancerFailed: Multiple tagged security groups found for instance
```

Run the audit helper and remove any orphaned tags:

```bash
./scripts/cleanup-stale-sg-tags.sh <cluster-name> <region>
# Example:
./scripts/cleanup-stale-sg-tags.sh forge-customer-ai us-west-2
```

This script is interactive and safe (tag-removal only, no SG deletion).
Alternatively, `tofu apply` also runs this cleanup automatically via the
`null_resource.cleanup_node_sg_tags` provisioner.

### 2. Remove termination protection from ForgeCluster CR (if set)

```bash
kubectl patch forgecluster <name> -n forge-system \
  --type=merge -p '{"spec":{"terminationProtection":false}}'
```

### 3. Delete ForgeCluster CR so the operator can clean up Helm releases

```bash
kubectl delete forgecluster <name> -n forge-system
# Wait for deletion to complete before proceeding
kubectl wait --for=delete forgecluster/<name> -n forge-system --timeout=120s
```

### 4. Delete any manually-created LoadBalancer services (prevents SG leak)

```bash
kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer -o name
# Delete each one:
kubectl delete svc forge-api -n forge
```

Wait for the corresponding ELB to be de-provisioned (~30s):
```bash
kubectl get svc forge-api -n forge  # should show no EXTERNAL-IP
```

---

## Running the destroy

```bash
tofu destroy -var-file=<env>.tfvars
```

The `null_resource.cleanup_node_sg_tags` will automatically remove the
`kubernetes.io/cluster/<name>` tag from all SGs in the region as part of the
destroy run.

---

## Post-destroy verification

```bash
# Verify no SGs with the cluster tag remain:
aws ec2 describe-security-groups \
  --region <region> \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/<cluster-name>" \
  --query "SecurityGroups[].{Id:GroupId,Name:GroupName}"
# Expected: empty list []

# Verify no ELBs for the cluster remain:
aws elb describe-load-balancers \
  --region <region> \
  --query "LoadBalancerDescriptions[?contains(LoadBalancerName, '<cluster-name>')].LoadBalancerName"

# Verify no EKS cluster endpoint:
aws eks describe-cluster --name <cluster-name> --region <region>
# Expected: ResourceNotFoundException
```

---

## Workaround if stale SG tag is found post-rebuild (TKT-102 emergency fix)

If the cluster is already rebuilt and LoadBalancer provisioning is failing:

```bash
# 1. Identify the stale SG:
aws ec2 describe-security-groups \
  --region <region> \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/<cluster-name>" \
  --query "SecurityGroups[].{Id:GroupId,Name:GroupName,Created:Tags[?Key=='aws:cloudformation:stack-name']|[0].Value}"

# 2. Remove the tag from the OLD SG (not the new one):
aws ec2 delete-tags \
  --region <region> \
  --resources <stale-sg-id> \
  --tags "Key=kubernetes.io/cluster/<cluster-name>"

# 3. Within ~40s, the LB provisioner retries and EnsuredLoadBalancer fires.
```

See `scripts/cleanup-stale-sg-tags.sh` for an interactive version.
