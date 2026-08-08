# Troubleshooting

Start here:

```console
kubectl logs deployment/my-server-satisfactory-server
kubectl describe pod -l app.kubernetes.io/name=satisfactory-server
```

The entrypoint is chatty and most failures announce themselves in the first
twenty lines of the log.

## `helm install` fails before anything is created

The chart rejects configurations the image cannot run under, so these never
become a pod:

| Message contains | Cause | Fix |
|---|---|---|
| `runAsUser is N, which the ... image cannot run as` | A non-root UID other than 1000 | Use 1000, or 0 — see [configuration.md](configuration.md#running-as-root) |
| `runAsGroup is N` | A non-root GID other than 1000 | Same; the entrypoint checks the GID too |
| `runAsNonRoot is true` | `runAsUser: 0` with `runAsNonRoot: true` | Set `runAsNonRoot: false` when running as root |
| `does not match podSecurityContext.runAsUser` | An explicit `puid` fighting the security context | Drop the `puid` override and let it derive |
| `resolved PUID is 0` | Root mode with `fsGroup: 0` or `puid: 0` | The image refuses to run the server as root; pick a non-root ID |
| `hostNetwork is enabled together with service.type LoadBalancer` | Both set | Use `ClusterIP` with `hostNetwork` |

## The pod CrashLoops immediately

### `Failed to install app '1690800' (Missing configuration)`, exit code 8

SteamCMD logs in, then fails about a second later without downloading anything.
The entrypoint runs under `set -e`, so the container exits 8 and Kubernetes
restarts it — usually two or three times before one attempt succeeds.

The cause is a cold SteamCMD app-info cache. On a cold start SteamCMD fetches
app metadata in the background while `app_update` runs in the foreground; when
`app_update` wins that race there is no configuration for app 1690800 yet, and
it fails with this message. The cache lives in the steam user's home, which is
on the container filesystem — and every container start gets a fresh one, so
the race is rerun on every start rather than only on a first install.

**The chart avoids this** by keeping that cache on the `config` volume, so it
stays warm across restarts and pod replacements. If you are seeing this
repeatedly, check the mount survived:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  ls /home/steam/.steam/steam/appcache/appinfo.vdf
```

A missing `appinfo.vdf` means the cache is not being persisted — most likely
`persistence.config.enabled` is `false`, which puts it on an `emptyDir` that is
discarded with the pod.

**A genuinely fresh install still races**, because nothing can warm a cache that
has never been written. Expect a few restarts on a brand-new volume, then clean
starts from then on. Watch it make progress rather than counting restarts:

```console
kubectl logs -f deployment/my-server-satisfactory-server
```

Treat it as a real failure only if it keeps looping without the download ever
starting.

### `Current user (N:N) is not root (0:0), and doesn't match the steam user/group`

The container is running as a UID or GID the image was not built for. The chart
normally catches this at render time; seeing it here means the security context
was changed by something else — a mutating webhook, a `PodSecurityPolicy`
replacement, or a namespace-level default. Check what actually landed:

```console
kubectl get pod -l app.kubernetes.io/name=satisfactory-server \
  -o jsonpath='{.items[0].spec.securityContext}'
```

### `The current user does not have write permissions for /config`

The volume is not writable by the user the server runs as. In non-root mode the
entrypoint does not fix ownership itself — it relies on `fsGroup`, and some
storage backends (NFS, several CSI drivers) ignore it.

Run as root and let the entrypoint chown the volume. See
[configuration.md](configuration.md#running-as-root) — and note it needs the
extra capabilities, not just `runAsUser: 0`.

### `Your CPU model is configured as "Common KVM processor"`

The nodes are VMs presenting a generic CPU model, and Satisfactory crashes on
those. Fix it at the hypervisor by passing through a real CPU model
(`host-passthrough` or a named model). If you do not control the hypervisor,
`server.vmOverride: true` skips the check — but the crash it warns about remains
possible.

### The pod exits cleanly after printing a lot of environment variables

`server.debug: true`. It is a one-shot diagnostic dump, not a logging level, and
the entrypoint exits deliberately. Set it back to `false`.

## The pod never becomes Ready

### On a first install, while SteamCMD downloads

Normal. The install is about 3GB on disk; how long it takes depends on your
connection. Watch it:

```console
kubectl logs -f deployment/my-server-satisfactory-server
```

### The pod restarts partway through the download

The startup probe ran out of attempts. The default budget is 120 attempts at 15s
— 30 minutes. On a slow connection:

```yaml
probes:
  startup:
    failureThreshold: 240   # 1 hour
```

Nothing is lost; the download resumes from where it stopped.

### Downloaded fine, but the probe never passes

Check the health check by hand:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  bash /home/steam/healthcheck.sh
```

It POSTs to the server's HTTPS API on `SERVERGAMEPORT` and expects
`.data.health == "healthy"`. If it fails, the game server process is not up —
look further back in the log for a crash, and check the memory situation below.

## Log lines that look alarming but are not

### `Checking available storage: 4GB detected` and `it will probably fail`

Harmless with the chart's default layout, and it prints on every start.

The entrypoint measures free space on its current directory, which is under
`/config` — the small saves claim. The game installs into `/config/gamefiles`,
a separate and much larger claim it never looks at. Splitting the claims is what
makes it check the wrong filesystem. Confirm there is really space:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  df -h /config /config/gamefiles
```

It becomes a real warning if you set `persistence.gamefiles.enabled: false`,
since everything then shares the `config` claim and that number is the one that
matters.

### `Checking available memory: 99GB detected`

That is the node's memory, not the pod's. The check reads host memory rather
than the cgroup limit, so it will happily report a comfortable figure for a pod
limited to far less and will never warn you about an under-provisioned server.
Size memory yourself with `resources` — see the OOMKilled section above.

## Players can see the server but cannot join

A port is not getting through. Which one depends on the symptom:

| Symptom | Missing |
|---|---|
| Server appears in the list, joining never completes | 7777/UDP |
| Server reachable, client reports API connectivity errors | 8888/TCP |

All three ports must be open end to end — Service, load balancer, and router.
8888/TCP became mandatory in Satisfactory 1.1, so a setup carried over from 1.0
that only forwards 7777 will fail this way.

```console
kubectl get svc my-server-satisfactory-server -o yaml | grep -A3 ports
```

You should see 7777/TCP, 7777/UDP and 8888/TCP. If UDP is missing from the
Service, your load balancer may be rejecting mixed protocols — see
[networking.md](networking.md#if-your-provider-rejects-mixed-protocols).

`kubectl port-forward` cannot be used to test this: it only carries TCP.

### …and every port is open

If you set `tls.enabled`, suspect the certificate before the network. The client
verifies the hostname strictly and rejects wildcards, and a certificate that
does not name the exact host the player typed fails the handshake with the same
`Failed to connect to server API` — with nothing logged server-side, because the
connection never gets far enough to log.

Check what the certificate actually claims, against what players type:

```console
kubectl exec deploy/my-server-satisfactory-server -- \
  openssl x509 -noout -subject -ext subjectAltName \
  -in /config/gamefiles/FactoryGame/Certificates/cert_chain.pem
```

Setting `tls.enabled: false` reverts to the self-signed certificate, which
always works and always warns. That is the quickest way to confirm the
certificate is the problem rather than the network.

## The client says the server is unclaimed

It is. A new server has to be claimed from the game client, with an admin
password set. The chart cannot do it. See
[configuration.md](configuration.md#claiming-the-server).

## The pod is OOMKilled

```console
kubectl get pod -l app.kubernetes.io/name=satisfactory-server \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'
```

A large factory outgrows the 12Gi default limit. Raise it:

```yaml
resources:
  requests:
    memory: 12Gi
  limits:
    memory: 20Gi
```

You lose whatever happened since the last autosave. Lowering the autosave
interval in the game settings limits the damage while you size this properly.

## The server is sluggish under load

Check for CPU throttling:

```console
kubectl top pod -l app.kubernetes.io/name=satisfactory-server
```

The chart sets no CPU limit by default, precisely because throttling the
simulation tick loop degrades the game for everyone connected. If you added one,
that is the first thing to remove.

## Shutdown and saving

**The server does not save when the pod is deleted.** Anything since the last
autosave is lost. This was measured on a live server: the game process received
the shutdown signal, called `RequestExit`, and exited in under two seconds
without writing a save file.

There is no configuration that changes this, and in particular **a `preStop`
hook sending SIGINT does not help**. The image's entrypoint already traps
SIGTERM and forwards SIGINT to the game process:

```bash
trap shutdown SIGINT SIGTERM   # shutdown() runs: kill -INT $satisfactory_pid
```

So Kubernetes ignoring the image's `STOPSIGNAL SIGINT` is harmless — the game
gets an INT either way, and still does not save. A hook running `kill -INT 1`
would only duplicate what already happens.

One detail worth knowing when reading the log: the entrypoint prints
`Received SIGINT. Shutting down.` as a fixed string, whichever signal actually
arrived. Kubernetes sends SIGTERM; the log says SIGINT regardless.

The rotating autosaves are therefore the only protection. Shorten the interval
in the game's own server settings if losing several minutes matters, and take a
volume snapshot before anything disruptive:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  ls -la /config/saved/server
```

Scope: tested once, on the image version this chart pins, by deleting the pod
of a running claimed server. It shows this server exited without saving; it is
not proof the game never saves under any shutdown path.

## Getting more detail

Satisfactory's own logs are inside the volume, not on stdout:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  ls /config/gamefiles/FactoryGame/Saved/Logs
```

By default the entrypoint prunes these on each start. Keep them with
`server.log: true` when you are chasing something across restarts.
