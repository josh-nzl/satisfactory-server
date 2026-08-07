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

### On a first install, for 10-30 minutes

Normal. SteamCMD is downloading roughly 15GB. Watch it:

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

The image declares `STOPSIGNAL SIGINT`, but **Kubernetes ignores `STOPSIGNAL`
and always sends SIGTERM**. Whether the server saves cleanly on SIGTERM has not
been verified in this chart, so treat it as unknown rather than assumed: the
rotating autosaves are what actually protect you.

If you observe unsaved progress being lost on pod deletion, forcing a SIGINT is
worth trying:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "kill -INT 1; sleep 30"]
terminationGracePeriodSeconds: 60
```

If you test this either way, the result is worth contributing back.

## Getting more detail

Satisfactory's own logs are inside the volume, not on stdout:

```console
kubectl exec deployment/my-server-satisfactory-server -- \
  ls /config/gamefiles/FactoryGame/Saved/Logs
```

By default the entrypoint prunes these on each start. Keep them with
`server.log: true` when you are chasing something across restarts.
