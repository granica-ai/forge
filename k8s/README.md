# Kubernetes manifests

`deploy/k8s` is for concrete manifests, templates, and environment examples.

For the durable deployment model, see
[operator/README.md](../../operator/README.md).

## QueryUI demo path

Reusable starting point:

- [templates/queryui-demo-forgecluster.yaml](./templates/queryui-demo-forgecluster.yaml)
- [queryui-demo-runbook.md](./queryui-demo-runbook.md)

Concrete examples:

- [examples/queryui-staging-forgecluster.yaml](./examples/queryui-staging-forgecluster.yaml) — shared staging cluster
- [examples/queryui-isolated-forgecluster.yaml](./examples/queryui-isolated-forgecluster.yaml) — isolated single-tenant cluster

The template is generic. The examples show how to fill in namespaces, bucket
names, IRSA role ARNs, demo table path, and release tag.
