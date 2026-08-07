# Configuration

## Claiming the server

A fresh server is unclaimed. It will run, answer health checks and show up in
the client, but it will not host a game until someone claims it. The chart
cannot do this for you — there is no environment variable for it.

1. In Satisfactory, open **Server Manager** and add the server by address.
2. The client reports the server as unclaimed and asks for an administrator
   password. Set one.
3. Name the server, then create a new game or upload an existing save.

The admin password and server name are stored in the `config` volume, so they
survive a pod restart and a `helm upgrade`.

## Server settings

Every `server.*` value maps to an environment variable the image understands.

| Value | Variable | Default | Notes |
|---|---|---|---|
| `server.maxPlayers` | `MAXPLAYERS` | `4` | |
| `server.maxTickRate` | `MAXTICKRATE` | `30` | |
| `server.maxObjects` | `MAXOBJECTS` | `2162688` | Raise for very large factories |
| `server.autosaveNum` | `AUTOSAVENUM` | `5` | Rotating autosaves kept |
| `server.serverStreaming` | `SERVERSTREAMING` | `true` | Asset streaming |
| `server.disableSeasonalEvents` | `DISABLESEASONALEVENTS` | `false` | Turns off FICSMAS |
| `server.skipUpdate` | `SKIPUPDATE` | `false` | Skips the SteamCMD update on start |
| `server.timeout` | `TIMEOUT` | `30` | Client timeout, seconds |
| `server.multihome` | `MULTIHOME` | `::` | Listening interface |
| `server.debug` | `DEBUG` | `false` | **Exits the container**, see below |
| `server.log` | `LOG` | `false` | `true` keeps old logs instead of pruning |
| `server.vmOverride` | `VMOVERRIDE` | `false` | Skips the CPU model check |
| `server.gamePort` | `SERVERGAMEPORT` | `7777` | TCP and UDP, both required |
| `server.messagingPort` | `SERVERMESSAGINGPORT` | `8888` | TCP, required since 1.1 |
| `server.beta.enabled` | `STEAMBETA` | `false` | Experimental branch |
| `server.beta.id` | `STEAMBETAID` | unset | Custom branch, for testing |
| `server.beta.key` | `STEAMBETAKEY` | unset | Branch password |

Anything not listed here can go through `extraEnv`, which renders after the
generated block and therefore wins on a duplicate name:

```yaml
extraEnv:
  - name: SOME_NEW_VARIABLE
    value: "whatever"
```

### `server.debug` is not a logging switch

Setting it makes the entrypoint print its environment and host details and then
**exit**. The pod will CrashLoop for as long as it is set. Turn it on to collect
the dump from `kubectl logs`, read it, then turn it off.

### `server.vmOverride` and virtual machines

The entrypoint refuses to start when the CPU identifies itself as
`Common KVM processor` or anything containing `QEMU`, because Satisfactory
crashes on those. If your nodes are VMs, the right fix is at the hypervisor —
pass a real CPU model through (`host-passthrough`, or a named model) rather than
the generic default. `server.vmOverride: true` skips the check for when you do
not control the hypervisor, but the crash it was warning about is still possible.

### Keeping the beta key out of values

```yaml
server:
  beta:
    enabled: true
extraEnv:
  - name: STEAMBETAKEY
    valueFrom:
      secretKeyRef:
        name: satisfactory-beta
        key: steam-beta-key
```

## Running as root

The default is a non-root pod: UID and GID 1000, matching the `steam` user built
into the image, which satisfies the `restricted` Pod Security Standard. It
depends on your CSI driver honouring `fsGroup` to make the volumes writable,
because the entrypoint only fixes ownership itself when it runs as root.

If your storage ignores `fsGroup` — NFS and some CSI drivers do — or a volume
already carries the wrong ownership, run as root and let the entrypoint chown
the volume and drop privileges with `gosu`:

```yaml
podSecurityContext:
  runAsUser: 0
  runAsNonRoot: false
  fsGroup: 1000          # the UID/GID the server ends up running as

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  capabilities:
    drop:
      - ALL
    add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - FOWNER
  seccompProfile:
    type: RuntimeDefault
```

**The capabilities matter.** Dropping `ALL` and running as root gives you a
container that cannot perform the `chown` the root path exists to do. This is
why the chart ships the whole block rather than telling you to set
`runAsUser: 0`.

In root mode `PUID`/`PGID` come from `fsGroup`, so the on-disk ownership and the
user the server ends up running as agree. Override them explicitly if you need
something else:

```yaml
puid: 1500
pgid: 1500
```

Neither may resolve to 0 — the image refuses to run the server as root and the
chart rejects it at render time.

### Why `runAsUser` is restricted to 1000 or 0

The entrypoint compares the UID *and* GID it is running as against the `steam`
user built into the image and exits if either differs:

```
ERROR: Current user (1234:1234) is not root (0:0), and doesn't match the
steam user/group (1000:1000).
```

Running as some other non-root UID requires rebuilding the image with matching
build arguments, which is outside what a chart can do. So the chart rejects it
during `helm install`, where you get a message, rather than at container start,
where you get a CrashLoop.

## Resources

Upstream asks for 8GB minimum and recommends 8-16GB. The entrypoint prints a
warning when it sees less than 8GB available, but starts anyway.

The chart requests 8GB and limits at 12GB, and deliberately sets **no CPU
limit** — throttling the simulation tick loop degrades the game for everyone
connected. A CPU request reserves capacity without capping bursts.

```yaml
resources:
  requests:
    cpu: 4
    memory: 12Gi
  limits:
    memory: 16Gi
```

Be careful with the memory limit: a server that exceeds it is OOMKilled
mid-tick, and while autosaves limit the damage, you lose whatever happened since
the last one.

## Probes

All three probes run the image's own `healthcheck.sh`, which POSTs a HealthCheck
call to the server's HTTPS API on the game port. Because it reads
`SERVERGAMEPORT`, changing `server.gamePort` moves the probe with it.

- **startup** — 120 attempts every 15s, a 30 minute budget for the first
  SteamCMD download.
- **readiness** — keeps the pod out of the Service endpoints until the game API
  answers, so players are not routed to a server that is still booting.
- **liveness** — restarts the pod if the server stops responding.

## Game config files

Satisfactory's own `.ini` files live in the `config` volume at
`/config/gamefiles/FactoryGame/Saved/Config/LinuxServer/`. The chart does not
template them. To edit them:

```console
kubectl exec -it deploy/my-server-satisfactory-server -- \
  bash -c 'cat /config/gamefiles/FactoryGame/Saved/Config/LinuxServer/Engine.ini'
```

To manage them declaratively, mount a ConfigMap over the specific file with
`extraVolumes`/`extraVolumeMounts` and a `subPath`. Note that the game rewrites
these files, so a read-only mount will produce errors in the server log.
