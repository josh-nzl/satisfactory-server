# Installation

## Adding the repository

```console
helm repo add satisfactory https://josh-nzl.github.io/satisfactory-server
helm repo update
```

Or skip the repository and pull the chart as an OCI artifact:

```console
helm install my-server oci://ghcr.io/josh-nzl/charts/satisfactory-server
```

## A minimal install

```console
helm install my-server satisfactory/satisfactory-server --namespace games --create-namespace
```

That gives you a single server with the defaults: 4 players, two persistent
claims, and a `LoadBalancer` Service on ports 7777/TCP, 7777/UDP and 8888/TCP.

## A more typical values file

```yaml
server:
  maxPlayers: 8

service:
  type: LoadBalancer
  annotations:
    # However your load balancer implementation wants to be told which address
    # to hand out. This differs per provider.
    example.com/address-pool: games

persistence:
  config:
    storageClass: fast-replicated
    size: 10Gi
  gamefiles:
    storageClass: bulk
    size: 30Gi

resources:
  requests:
    cpu: 4
    memory: 12Gi
  limits:
    memory: 16Gi
```

```console
helm install my-server satisfactory/satisfactory-server -f values.yaml
```

## The first start

SteamCMD downloads roughly 15GB before the server answers anything. Expect
10-30 minutes, longer on a slow link. The pod is un-Ready throughout, which is
what the startup probe's long budget is for.

```console
kubectl logs -f deployment/my-server-satisfactory-server
```

If the startup probe runs out of attempts the pod restarts. Nothing is lost —
the download resumes — but raise the budget so it stops happening:

```yaml
probes:
  startup:
    failureThreshold: 240   # 240 x 15s = 1 hour
```

## Upgrading

```console
helm repo update
helm upgrade my-server satisfactory/satisfactory-server -f values.yaml
```

The `Recreate` strategy means the old pod is terminated before the new one
starts, so there is a gap of a few minutes while the new pod boots. That is
deliberate: both pods cannot hold a `ReadWriteOnce` volume at once, and a
`RollingUpdate` would deadlock instead.

Upgrading the chart does not upgrade the game. The container updates
Satisfactory through SteamCMD on every start unless `server.skipUpdate` is true,
so a plain `kubectl rollout restart` is enough to pick up a new game build.

To move to a specific container release:

```yaml
image:
  tag: v1.9.10
```

## Rolling back

```console
helm rollback my-server
```

This rolls back the Kubernetes objects only. It does not roll back the save, and
it does not downgrade the game — the container will re-update to the current
build on its next start. To pin the game where it is while you investigate, set
`server.skipUpdate: true`.

## Uninstalling

```console
helm uninstall my-server
```

The `config` claim carries `helm.sh/resource-policy: keep` and is **left
behind** — that claim holds your saves. The `gamefiles` claim is deleted, since
its contents are re-downloadable.

To remove the saves too:

```console
kubectl delete pvc my-server-satisfactory-server-config
```

There is no undo for that. Take a copy first if you might want the world back —
see [storage-and-backups.md](storage-and-backups.md).

If you reinstall with the same release name while the old claim still exists,
the new release adopts it and the world comes back.

## Using claims you already have

Migrating from another chart, or restoring from a snapshot:

```yaml
persistence:
  config:
    existingClaim: satisfactory-config
  gamefiles:
    existingClaim: satisfactory-gamefiles
```

The chart then creates no claims at all and mounts what you point it at. The
`config` claim must contain the `saved/` directory at its root, matching the
layout the image expects — `/config/saved`, `/config/backups`, `/config/logs`.
