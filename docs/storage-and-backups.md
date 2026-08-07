# Storage and backups

## Two claims, on purpose

| Claim | Mount | Default size | Kept on uninstall | Holds |
|---|---|---|---|---|
| `config` | `/config` | 5Gi | Yes | Saves, blueprints, backups, logs, server settings |
| `gamefiles` | `/config/gamefiles` | 25Gi | No | The SteamCMD game installation |

The split exists because the two have nothing in common. `config` is small,
irreplaceable, and worth snapshotting often. `gamefiles` is large, grows with
every game update, and can always be re-downloaded. Keeping them apart means
your snapshot schedule is not dragging 15GB of re-downloadable game files
around, and it lets the bulk sit on cheaper storage.

```yaml
persistence:
  config:
    storageClass: fast-replicated
    size: 10Gi
  gamefiles:
    storageClass: bulk
    size: 30Gi
```

`gamefiles` mounts *inside* `/config` because that is where the image expects
the installation. Nesting one volume inside another is fine; the kubelet mounts
them in order.

### Sizing

`gamefiles` needs 15GB or so today and grows with each game update — 25Gi gives
some headroom. `config` holds saves measured in tens of megabytes plus
`server.autosaveNum` rotating autosaves and the image's own backups; 5Gi is
already generous, but a long-running world with a big autosave count can grow.

### One claim instead of two

```yaml
persistence:
  gamefiles:
    enabled: false
```

Everything then lives in the `config` claim, which needs to be big enough for
the game files too. Simpler, at the cost of dragging the game install into every
snapshot.

### Disposable game files

```yaml
persistence:
  gamefiles:
    type: emptyDir
    emptyDir:
      sizeLimit: 30Gi
```

The full ~15GB download repeats on every pod start, which turns a 30-second
restart into a 20-minute one. Only sensible where node-local storage is fast and
the pod rarely moves.

## Backups

The image keeps its own rotating backups inside the volume, at
`/config/backups`, and takes one when the container first starts. That protects
you from an in-game mistake. It does not protect you from losing the volume.

The chart does not ship a backup job. Two approaches that work:

### Volume snapshots

If your CSI driver supports them, snapshot the `config` claim on a schedule.
This is the least intrusive option — no second mount, no interaction with the
running server — and it is why the claims are split in the first place.

### Copying the saves out

```console
kubectl exec deploy/my-server-satisfactory-server -- \
  tar czf - -C /config saved backups > satisfactory-$(date +%F).tar.gz
```

Straightforward, and it runs against the live server. A save written mid-`tar`
could be captured half-written, so prefer a file that the server is not
currently rotating — the autosaves are safer than the active save.

Note that anything mounting the `config` claim at the same time as the server
needs `ReadWriteMany`, which the default `ReadWriteOnce` will not give you. That
constraint is why a backup `CronJob` is not in the chart: it would only work on
a subset of storage backends, and failing quietly on the rest is worse than not
being there.

## Importing an existing save

Saves live in `/config/saved/server`.

```console
kubectl cp my-world.sav \
  games/my-server-satisfactory-server-xxxxx:/config/saved/server/my-world.sav
```

Then load it from the game client's server manager. Ownership matters: the file
must be readable by the user the server runs as (1000 by default). If you copied
it as root, fix it:

```console
kubectl exec deploy/my-server-satisfactory-server -- \
  ls -l /config/saved/server
```

Uploading through the game client's server manager avoids the ownership question
entirely and is the easier path for a single save.

## Moving a world to a new release

The `config` claim carries `helm.sh/resource-policy: keep`, so it survives
`helm uninstall`. Reinstalling with the same release name in the same namespace
adopts the existing claim and the world comes back.

To attach it to a differently-named release:

```yaml
persistence:
  config:
    existingClaim: my-server-satisfactory-server-config
```

## Disabling persistence

```yaml
persistence:
  config:
    enabled: false
```

`/config` becomes an `emptyDir` and the world is destroyed when the pod is
replaced. For testing the chart, not for playing. `helm install` prints a warning
when this is set.
