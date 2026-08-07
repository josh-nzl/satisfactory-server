# Satisfactory server Helm chart

A Helm chart for running a [Satisfactory](https://www.satisfactorygame.com/)
dedicated server on Kubernetes, wrapping the community-standard
[`wolveix/satisfactory-server`](https://github.com/wolveix/satisfactory-server)
image.

The chart aims to be boring: one `Deployment`, one `Service`, two claims, and
enough validation that a misconfiguration fails at `helm install` instead of
becoming a pod that CrashLoops with an error only visible in the container log.

## Requirements

| | |
|---|---|
| Kubernetes | 1.26 or newer |
| Memory | 8GB minimum, 8-16GB recommended |
| Storage | ~30GB across two claims |
| CPU | A CPU the game recognises; see [troubleshooting](docs/troubleshooting.md) if your nodes are VMs |

The 1.26 floor comes from the default Service, which carries TCP and UDP on a
single `LoadBalancer`. Mixed protocols on one load balancer went GA in 1.26.

## Installing

```console
helm repo add satisfactory https://josh-nzl.github.io/satisfactory-server
helm repo update
helm install my-server satisfactory/satisfactory-server
```

Or from the OCI registry:

```console
helm install my-server oci://ghcr.io/josh-nzl/charts/satisfactory-server
```

> **The first start takes 10-30 minutes.** SteamCMD downloads roughly 15GB of
> game files before the server responds to anything, and the pod stays un-Ready
> for the whole of that. This is normal. Watch it with
> `kubectl logs -f deployment/my-server-satisfactory-server`.

Once the pod is Ready, add the server in the game client and claim it — a fresh
server is unclaimed and will not accept a game until someone sets an admin
password. See [docs/configuration.md](docs/configuration.md).

The server needs **three** ports reachable: 7777/TCP, 7777/UDP and 8888/TCP.
All three have been mandatory since Satisfactory 1.1, and forwarding a subset is
the usual cause of a server that is visible but unjoinable — see
[docs/networking.md](docs/networking.md).

## Documentation

| Document | Covers |
|---|---|
| [Chart reference](charts/satisfactory-server/README.md) | Every value, generated from `values.yaml` |
| [Installation](docs/installation.md) | Install, upgrade, rollback, uninstall |
| [Configuration](docs/configuration.md) | Server settings, running as root, claiming the server |
| [Networking](docs/networking.md) | Service types, mixed protocols, firewall ports |
| [Storage and backups](docs/storage-and-backups.md) | The two claims, importing saves, backups |
| [Troubleshooting](docs/troubleshooting.md) | The failure modes worth recognising on sight |

## What the chart does and does not do

**Does:**

- Derives `PUID`/`PGID` from the pod security context, so the two cannot drift
  apart and strand the container on startup.
- Refuses, at render time, the security contexts the image cannot run under.
- Defaults to a non-root pod that satisfies the `restricted` Pod Security
  Standard, with a supported root path for storage that ignores `fsGroup`.
- Keeps the saves claim when you uninstall the release, and drops the
  re-downloadable game files claim.
- Uses the image's own health check for all three probes, with a startup budget
  sized for the initial download.

**Does not:**

- Claim the server, or set an admin password. That is a game-client action.
- Back the saves up anywhere off-cluster. The image keeps rotating backups
  inside the volume; getting them off it is your call. See
  [docs/storage-and-backups.md](docs/storage-and-backups.md).
- Run more than one replica. A Satisfactory server is one process owning one
  world on one `ReadWriteOnce` volume.

## Development

```console
helm lint charts/satisfactory-server
helm unittest charts/satisfactory-server        # requires the helm-unittest plugin
helm template t charts/satisfactory-server | kubeconform -strict -summary
helm-docs --chart-search-root=charts --template-files=README.md.gotmpl
```

`values.yaml` is the source of truth for the chart README — edit the comments
there, then regenerate with `helm-docs`. CI fails on a stale README.

### Verifying a release

CI lints, unit-tests and schema-validates the rendered manifests. It does not
install the chart: a real install pulls ~15GB through SteamCMD into a pod that
wants 8GB of RAM, which a hosted runner cannot do, and a job that always timed
out would read as coverage that does not exist.

Before tagging a release, run this against a real cluster:

1. `helm install` with defaults; confirm both claims bind and the pod starts
   without the entrypoint's UID-mismatch error.
2. Watch the pod through the SteamCMD download and confirm it becomes Ready.
3. `kubectl exec deploy/<release>-satisfactory-server -- bash /home/steam/healthcheck.sh`
   returns healthy.
4. Connect from the game client, claim the server, and confirm a save persists
   across `kubectl delete pod`.
5. `helm uninstall`; confirm the config claim survives and the gamefiles claim
   does not.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with Coffee Stain Studios, and does not
distribute the game. The container image it deploys downloads the dedicated
server through SteamCMD at runtime.
