# Running kagent on Azure Kubernetes Service

AKS is not part of kagent's test matrix: CI runs on Kind with Kubernetes 1.37.
This page lists what the charts require from an AKS cluster, and what is
unverified. It describes kagent with Substrate v1.1.0-alpha1 and AKS as documented
in November 2026.

> [!WARNING]
> [kagent-dev/substrate#191](https://github.com/kagent-dev/substrate/issues/191)
> is an open report of gVisor and microVM workers never registering on AKS 1.37.1,
> with Substrate 1.0.0 and 1.0.1 on Ubuntu 24.04 nodes. Its cause is not known.
> Verify an installation as described in [Verify](#verify) before relying on it.

## Kubernetes version and certificate APIs

Use Kubernetes 1.37 or later, which
[AKS lists as generally available](https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions).
From 1.37, `PodCertificateRequest` and `ClusterTrustBundle` are served at
`certificates.k8s.io/v1` by default. Substrate uses `v1` when it is available, so
no feature gates or API server flags are needed. Check that the cluster serves
both, using a current `kubectl`:

```sh
kubectl api-resources --api-group=certificates.k8s.io
```

The output must include `clustertrustbundles` and `podcertificaterequests`.

## Nodes

### Azure Linux

No Azure Linux result is recorded for kagent, so treat it as unverified. Use
Azure Linux 3: AKS
[stopped supporting Azure Linux 2 in November 2025](https://learn.microsoft.com/en-us/azure/aks/use-azure-linux).

The default `gvisor` sandbox class does not need a RuntimeClass, KVM, or gVisor
installed on the node. Atelet downloads the pinned gVisor release from
`storage.googleapis.com`, so nodes need egress to it. Sandbox CPU limits use
cgroup v2.

Worker pods are not privileged, but they run as root with added capabilities
including `SYS_ADMIN`, and with `Unconfined` seccomp and AppArmor profiles. Worker
and Atelet pods use host paths. Azure Policy or Pod Security Admission must
therefore allow these pods in the WorkerPool namespace and in `ate-system`. The
WorkerPool sets no SELinux options, so check for denials if your node image
enforces SELinux.

### Dedicated node pools

Every node that runs workers also needs Atelet. When using a dedicated pool,
select it in both places. Substrate:

```yaml
atelet:
  nodeSelector:
    kubernetes.azure.com/agentpool: agents
```

Kagent:

```yaml
substrateWorkerPool:
  template:
    nodeSelector:
      kubernetes.azure.com/agentpool: agents
```

### microVM workers

The `microvm` class needs nodes with `/dev/kvm`, so choose a VM size with nested
virtualization. It also needs the microVM SandboxConfig and assets. Atelet
advertises KVM as a node resource, and workers stay unscheduled without it:

```sh
kubectl get nodes -o custom-columns='NAME:.metadata.name,KVM:.status.allocatable.ate\.dev/kvm'
```

## Network policy

Substrate installs NetworkPolicies that restrict access to its control plane and
workers. AKS
[does not enforce NetworkPolicy by default](https://learn.microsoft.com/en-us/azure/aks/use-network-policies):
without an engine, the objects exist but have no effect. Enable one when creating
the cluster; Microsoft recommends Cilium.

## Snapshot storage

Substrate supports S3-compatible stores and GCS. It has no Azure Blob backend,
and Azure Blob does not implement the S3 API, so an Azure Blob container cannot be
used directly as a snapshot location.

### Bundled RustFS

`kagent install` deploys RustFS, which stores snapshots on a PersistentVolumeClaim.
The claim sets no StorageClass, so AKS provisions the cluster's default class, a
[Standard SSD Azure Disk](https://learn.microsoft.com/en-us/azure/aks/azure-csi-disk-storage-provision).
To use another class, make it the cluster default before installing.

The defaults suit development: a 1Gi volume and well-known credentials. Set your
own before the first install:

```yaml
rustfs:
  storageSize: 100Gi
  accessKey: <access-key>
  secretKey: <secret-key>
```

### External S3-compatible store

Disable RustFS and pass the endpoint and credentials through `objectStorePlugin`.
Both the API server and Atelet receive these settings. First create the bucket and
a `kagent-snapshot-store` Secret in `ate-system` holding the two keys, then add
Substrate values:

```yaml
rustfs:
  enabled: false
atelet:
  storageBackend: s3
ateApi:
  snapshotLocation: s3://kagent-snapshots/
objectStorePlugin:
  extraEnv:
    - name: AWS_ENDPOINT_URL
      value: https://s3.example.com
    - name: AWS_REGION
      value: us-east-1
    - name: AWS_S3_USE_PATH_STYLE
      value: "true"
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: kagent-snapshot-store
          key: AWS_ACCESS_KEY_ID
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: kagent-snapshot-store
          key: AWS_SECRET_ACCESS_KEY
```

The default Harnesses name a bucket too. Change it in the kagent values, and in
any Harness or SandboxTemplate you create:

```yaml
harnesses:
  snapshotLocation: s3://kagent-snapshots/kagent/
```

## Install

Reference both values files from the CLI configuration:

```yaml
install:
  kagent:
    valuesFiles: [kagent-values.yaml]
  substrate:
    valuesFiles: [substrate-values.yaml]
```

```sh
kagent --config config.yaml install
```

Atelet inherits the Substrate values. The database `kagent install` deploys is for
development; see [PostgreSQL](../helm/README.md#postgresql) to use your own.

## Verify

Pods can look healthy while workers cannot register, so check the WorkerPool:

```sh
kubectl get pods -n ate-system
kubectl get workerpools.ate.dev -n kagent
```

`READY` must reach `DESIRED`. If it does not, read the worker logs; repeated
`Could not acquire a worker epoch` messages match the issue linked above. Include
your node image, kernel, and network plugin when reporting a result.
