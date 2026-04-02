# QueryUI Demo Runbook

Use this runbook to stand up the QueryUI demo environment in a customer-like
cluster using the `ForgeCluster` path.

## What gets installed

Applying a QueryUI demo `ForgeCluster` creates or manages:

- `forge-api` in the Forge namespace
- Jupyter as the QueryUI notebook surface in the Forge namespace
- Spark Connect in the Crunch/runtime namespace
- Spark Operator in the Crunch/runtime namespace
- IRSA-backed service accounts and cross-namespace RBAC needed by the Spark runtime

The customer/demo user should think of this as one QueryUI deployment. The
split between Forge and Crunch namespaces is an implementation detail.

## Inputs you must provide

Start from:

- [templates/queryui-demo-forgecluster.yaml](./templates/queryui-demo-forgecluster.yaml)

Use these examples for reference:

- [examples/queryui-staging-forgecluster.yaml](./examples/queryui-staging-forgecluster.yaml) — shared staging cluster
- [examples/queryui-isolated-forgecluster.yaml](./examples/queryui-isolated-forgecluster.yaml) — isolated single-tenant cluster

Fill in:

- `spec.version`
- `spec.ecrRegistry`
- `spec.dataBucket`
- `spec.systemBucket`
- `spec.irsa.forgeApiRoleArn`
- `spec.irsa.sparkDriverRoleArn`
- `spec.namespaces.forge`
- `spec.namespaces.crunch`
- `spec.queryUi.demoTablePath`
- `spec.queryUi.jupyter.tokenSecretRef`

## Environment prerequisites

Before apply:

- the data bucket must exist
- the system bucket must exist
- the Jupyter auth secret must exist
- the Forge API IRSA role must trust the Forge namespace service account
- the Spark driver IRSA role must trust the Crunch runtime service account

Current staging example prerequisites (see `examples/queryui-staging-forgecluster.yaml`):

- data bucket: `staging-ai-dev-forge-data`
- system bucket: `forge-system-staging-us-west-2`
- Forge namespace: per your `ForgeCluster.spec.namespaces.forge`
- Crunch namespace: `crunch`

## Deploy

Apply the manifest:

```bash
kubectl --context <cluster-context> apply -f deploy/k8s/<your-queryui-demo>.yaml
kubectl --context <cluster-context> -n forge-system get forgecluster <name> -w
```

Wait for the `ForgeCluster` to reconcile `Ready`.

## Verify readiness

Check the Forge namespace:

```bash
kubectl --context <cluster-context> -n <forge-namespace> get deploy,pods
```

Expected:

- `forge-api` is `Running`
- Jupyter is `Running`

Check the Crunch/runtime namespace:

```bash
kubectl --context <cluster-context> -n <crunch-namespace> get deploy,pods,sparkconnect
```

Expected:

- Spark Operator controller is `Running`
- Spark Operator webhook is `Running`
- `spark-connect` exists and its server pod is `Running`

## QueryUI demo smoke test

Before handing the environment to a demo user:

1. Open QueryUI / Jupyter.
2. Confirm the notebook can reach Spark Connect.
3. Run a simple Spark read.
4. Run one end-to-end demo flow:
   - discover candidates
   - shortlist and select one
   - optional assess
   - optimize working copy
   - compare and read history

If the demo reaches history and compare without live cluster patching, the
environment is ready.
