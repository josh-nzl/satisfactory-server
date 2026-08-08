# satisfactory-server

![Version: 0.1.2](https://img.shields.io/badge/Version-0.1.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.9.10](https://img.shields.io/badge/AppVersion-v1.9.10-informational?style=flat-square)

A Helm chart for running a Satisfactory dedicated game server on Kubernetes

Runs the community-standard [`wolveix/satisfactory-server`][image] image as a
single-replica `Deployment` with persistent storage for saves and game files.

[image]: https://github.com/wolveix/satisfactory-server

## Before you install

- **The first start takes a while.** SteamCMD installs the game, about 3GB of
  game files before the server answers anything. The pod stays un-Ready for the
  whole of that, which is expected and what the long startup probe is for.
- **The server needs real memory.** Upstream asks for 8-16GB. The chart requests
  8GB and limits at 12GB by default.
- **Three ports, all required.** 7777/TCP (HTTPS API), 7777/UDP (game traffic)
  and 8888/TCP (messaging, mandatory since Satisfactory 1.1). Forward only TCP
  and clients find the server but never finish joining; miss 8888 and they hit
  API connectivity errors.
- **A new server must be claimed from the game client.** The chart cannot do it.

**Homepage:** <https://github.com/josh-nzl/satisfactory-server>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| josh-nzl |  | <https://github.com/josh-nzl> |

## Source Code

* <https://github.com/josh-nzl/satisfactory-server>
* <https://github.com/wolveix/satisfactory-server>

## Requirements

Kubernetes: `>=1.26.0-0`

## Installing

```console
helm repo add satisfactory https://josh-nzl.github.io/satisfactory-server
helm install my-server satisfactory/satisfactory-server
```

Or straight from the OCI registry:

```console
helm install my-server oci://ghcr.io/josh-nzl/charts/satisfactory-server
```

## Notes on a few values

### `podSecurityContext.runAsUser`

Only `1000` or `0` are accepted, and anything else fails at render time.

The image's entrypoint fixes volume ownership and drops privileges with `gosu`
when it runs as root. When it runs as anything else it compares both its UID and
its GID against the `steam` user built into the image and exits if either
differs. `PUID` and `PGID` are therefore derived from the security context rather
than being set independently, so the two cannot drift apart.

Running as root additionally needs `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`
and `FOWNER` added back to the container capabilities -- dropping `ALL` breaks
the very `chown` the root path exists to perform. See
[docs/configuration.md](../../docs/configuration.md).

### `persistence`

Two claims by default. `config` holds saves, blueprints, backups and server
settings and is kept when the release is uninstalled. `gamefiles` holds the
SteamCMD download, is not kept, and can be an `emptyDir` if you would rather
re-download than pay for the storage.

### `server.debug`

Not a verbose-logging switch. The entrypoint prints a diagnostic dump and then
**exits**, so the pod CrashLoops for as long as it is set.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for the server pod. Worth setting if only some nodes have the memory and CPU for a game server. |
| containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":false,"seccompProfile":{"type":"RuntimeDefault"}}` | Container-level security context. The defaults satisfy the `restricted` Pod Security Standard. Running as root additionally needs CHOWN, SETUID, SETGID, DAC_OVERRIDE and FOWNER added back -- see docs/configuration.md. |
| dnsConfig | object | `{}` | DNS config for the pod. |
| dnsPolicy | string | `""` | DNS policy. Set to `ClusterFirstWithHostNet` when `hostNetwork` is true. |
| extraEnv | list | `[]` | Additional environment variables, in raw Kubernetes `env` form. Rendered after the `server.*` block, so an entry here overrides the generated value. Use this for any variable the image gains before the chart catches up. |
| extraEnvFrom | list | `[]` | Additional environment sources (`envFrom`), for pulling whole ConfigMaps or Secrets into the container environment. |
| extraObjects | list | `[]` | Arbitrary extra manifests to render with the release. Strings are passed through `tpl`, so they can reference chart values. |
| extraVolumeMounts | list | `[]` | Additional volume mounts for the server container. |
| extraVolumes | list | `[]` | Additional volumes for the pod. |
| fullnameOverride | string | `""` | Override the full generated resource name. |
| hostNetwork | bool | `false` | Run the pod on the host network. Sidesteps the Service entirely; the ports are then claimed directly on the node. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"wolveix/satisfactory-server"` | Container image repository. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion when empty. Pinning this pins the *container*, not the game -- the container updates Satisfactory itself on every start unless `server.skipUpdate` is true. |
| imagePullSecrets | list | `[]` | Image pull secrets for private registries. |
| initContainers | list | `[]` | Init containers for the server pod. |
| lifecycle | object | `{}` | Container lifecycle hooks. |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| networkPolicy.allowedSourceRanges | list | `["0.0.0.0/0"]` | Source CIDRs allowed to reach the game ports. A public game server needs to be publicly reachable; narrow this for a friends-only or LAN server. |
| networkPolicy.egress.allowDNS | bool | `true` | Allow DNS to the cluster resolver. |
| networkPolicy.egress.allowedDestinations | list | `["0.0.0.0/0"]` | Destination CIDRs the server may reach, with private ranges excluded so a compromised game server cannot pivot into the rest of the network. |
| networkPolicy.egress.enabled | bool | `true` | Manage egress as well as ingress. Disabling this leaves egress unrestricted, which is safer than getting it wrong: the server must reach Steam on every start or the game update fails and the container exits. |
| networkPolicy.egress.exceptDestinations[0] | string | `"10.0.0.0/8"` |  |
| networkPolicy.egress.exceptDestinations[1] | string | `"172.16.0.0/12"` |  |
| networkPolicy.egress.exceptDestinations[2] | string | `"192.168.0.0/16"` |  |
| networkPolicy.egress.exceptDestinations[3] | string | `"169.254.0.0/16"` |  |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy for the server pod. |
| networkPolicy.extraEgress | list | `[]` | Additional egress rules, in raw NetworkPolicy form. |
| networkPolicy.extraIngress | list | `[]` | Additional ingress rules, in raw NetworkPolicy form. |
| nodeSelector | object | `{}` | Node selector for the server pod. |
| persistence.config.accessModes | list | `["ReadWriteOnce"]` | Access modes for the claim. |
| persistence.config.annotations | object | `{}` | Extra annotations for the claim. |
| persistence.config.enabled | bool | `true` | Persist `/config` (saves, blueprints, backups, logs, server settings). |
| persistence.config.existingClaim | string | `""` | Use an existing PersistentVolumeClaim instead of creating one. |
| persistence.config.labels | object | `{}` | Extra labels for the claim. |
| persistence.config.retain | bool | `true` | Keep the claim when the release is uninstalled. On by default, because deleting this claim destroys your saves. |
| persistence.config.size | string | `"5Gi"` | Size of the claim. Saves and backups are small; this is generous. |
| persistence.config.storageClass | string | `""` | StorageClass for the claim. Empty uses the cluster default; `-` disables dynamic provisioning entirely. |
| persistence.gamefiles.accessModes | list | `["ReadWriteOnce"]` | Access modes for the claim. |
| persistence.gamefiles.annotations | object | `{}` | Extra annotations for the claim. |
| persistence.gamefiles.emptyDir.sizeLimit | string | `""` | Size limit when `type` is `emptyDir`. |
| persistence.gamefiles.enabled | bool | `true` | Give the game installation its own volume at `/config/gamefiles`. When disabled, the game files live inside the `config` volume instead. |
| persistence.gamefiles.existingClaim | string | `""` | Use an existing PersistentVolumeClaim instead of creating one. |
| persistence.gamefiles.labels | object | `{}` | Extra labels for the claim. |
| persistence.gamefiles.retain | bool | `false` | Keep the claim when the release is uninstalled. Off by default: the contents are re-downloadable. |
| persistence.gamefiles.size | string | `"10Gi"` | Size of the claim. The Linux server files are around 3GB today, so this is mostly headroom for future game updates. Note most CSI drivers can grow a claim later but none can shrink one. |
| persistence.gamefiles.storageClass | string | `""` | StorageClass for the claim. This volume is disposable, so cheaper or slower storage is a reasonable choice. |
| persistence.gamefiles.type | string | `"pvc"` | `pvc` or `emptyDir`. `emptyDir` re-downloads the whole game (about 3GB) on every pod start, so only use it where the node has fast, cheap local storage. |
| pgid | string | `""` | Override `PGID`. Derived from `podSecurityContext.runAsGroup` when empty. |
| podAnnotations | object | `{}` | Annotations for the server pod. |
| podLabels | object | `{}` | Extra labels for the server pod. |
| podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000}` | Pod-level security context. `runAsUser` and `runAsGroup` must both be 1000 (the `steam` user and group baked into the image) or `runAsUser` must be 0. The image's entrypoint only fixes volume ownership when it runs as root; as a non-root user it compares both its UID *and* its GID against the built-in steam user and exits if either differs. Anything else is rejected at render time rather than left to CrashLoop. Non-root relies on the CSI driver honouring `fsGroup` to make the volumes writable -- the entrypoint checks `/config` is writable and exits if it is not. See docs/troubleshooting.md if you hit permission errors. |
| priorityClassName | string | `""` | PriorityClass for the server pod. |
| probes.liveness.enabled | bool | `true` | Enable the liveness probe. |
| probes.liveness.failureThreshold | int | `4` |  |
| probes.liveness.initialDelaySeconds | int | `0` |  |
| probes.liveness.periodSeconds | int | `30` |  |
| probes.liveness.successThreshold | int | `1` |  |
| probes.liveness.timeoutSeconds | int | `10` |  |
| probes.readiness.enabled | bool | `true` | Enable the readiness probe. Keeps the pod out of the Service endpoints until the game API actually answers. |
| probes.readiness.failureThreshold | int | `3` |  |
| probes.readiness.initialDelaySeconds | int | `0` |  |
| probes.readiness.periodSeconds | int | `15` |  |
| probes.readiness.successThreshold | int | `1` |  |
| probes.readiness.timeoutSeconds | int | `10` |  |
| probes.startup.enabled | bool | `true` | Enable the startup probe. This is what tolerates the very slow first boot, where SteamCMD downloads the game before the server can answer. |
| probes.startup.failureThreshold | int | `120` | 120 failures at 15s is a 30 minute budget for the first start. Raise it on a slow connection; the pod is killed and restarted if it is exceeded. |
| probes.startup.initialDelaySeconds | int | `30` |  |
| probes.startup.periodSeconds | int | `15` |  |
| probes.startup.successThreshold | int | `1` |  |
| probes.startup.timeoutSeconds | int | `10` |  |
| puid | string | `""` | Override `PUID`. Derived from `podSecurityContext.runAsUser` when empty, which is what keeps the environment and the security context from disagreeing. Only set this when running as root, where the two legitimately differ. |
| resources | object | `{"limits":{"memory":"12Gi"},"requests":{"cpu":2,"memory":"8Gi"}}` | Resource requests and limits. Upstream recommends 8-16GB of RAM; a busy factory will use all of it. There is deliberately no CPU limit by default: throttling the simulation tick loop degrades the game for everyone connected. |
| server.autosaveNum | int | `5` | Number of rotating autosave files to keep (`AUTOSAVENUM`). |
| server.beta.enabled | bool | `false` | Run the experimental game branch (`STEAMBETA`). |
| server.beta.id | string | `""` | Custom Steam beta branch name (`STEAMBETAID`). Only for testing. |
| server.beta.key | string | `""` | Password for the Steam beta branch (`STEAMBETAKEY`). Prefer `extraEnvFrom` with a Secret over putting this in values. |
| server.debug | bool | `false` | One-shot diagnostic dump (`DEBUG`). This is not a verbose logging switch: the entrypoint prints its environment and host details and then **exits**, so the pod will CrashLoop for as long as it is set. Turn it on to read the dump from `kubectl logs`, then turn it off again. |
| server.disableSeasonalEvents | bool | `false` | Disable the FICSMAS seasonal event (`DISABLESEASONALEVENTS`). |
| server.gamePort | int | `7777` | Game port, used for both TCP (HTTPS API) and UDP (game traffic) (`SERVERGAMEPORT`). |
| server.log | bool | `false` | Disable Satisfactory log pruning, keeping every log file (`LOG`). By default the entrypoint clears old logs on each start. |
| server.maxObjects | int | `2162688` | Object limit for the save (`MAXOBJECTS`). |
| server.maxPlayers | int | `4` | Maximum number of simultaneous players (`MAXPLAYERS`). |
| server.maxTickRate | int | `30` | Maximum simulation tick rate (`MAXTICKRATE`). |
| server.messagingPort | int | `8888` | Messaging port (`SERVERMESSAGINGPORT`). Required since Satisfactory 1.1: all three ports must be reachable or clients hit API connectivity errors. |
| server.multihome | string | `"::"` | Listening interface (`MULTIHOME`). `::` binds all IPv4 and IPv6 addresses. |
| server.serverStreaming | bool | `true` | Whether the game uses asset streaming (`SERVERSTREAMING`). |
| server.skipUpdate | bool | `false` | Skip the SteamCMD game update on container start (`SKIPUPDATE`). Speeds up restarts considerably, at the cost of running a stale game build. |
| server.timeout | int | `30` | Client timeout in seconds (`TIMEOUT`). |
| server.vmOverride | bool | `false` | Skip the CPU model check (`VMOVERRIDE`). The entrypoint refuses to start when the CPU reports itself as `Common KVM processor` or anything containing `QEMU`, because Satisfactory crashes on those. If your nodes are VMs, the real fix is to pass a proper CPU model through from the hypervisor; this value is the override for when you cannot. |
| service.annotations | object | `{}` | Annotations for the Service. This is where LoadBalancer implementations take their configuration (address pools, shared IPs, health check settings). |
| service.externalIPs | list | `[]` | Additional external IPs to attach to the Service. |
| service.externalTrafficPolicy | string | `"Cluster"` | `Cluster` or `Local`. `Local` preserves the client source address and avoids an extra hop, but only routes to nodes actually running the pod. |
| service.extraPorts | list | `[]` | Additional Service ports, in raw Kubernetes form. Useful for mods. |
| service.ipFamilies | list | `[]` | Explicit IP families for the Service. |
| service.ipFamilyPolicy | string | `""` | `SingleStack`, `PreferDualStack` or `RequireDualStack`. Left to the cluster default when empty. The server binds `::` by default, so it can serve both. |
| service.labels | object | `{}` | Extra labels for the Service. |
| service.loadBalancerClass | string | `""` | LoadBalancer class, when more than one implementation runs in the cluster. |
| service.loadBalancerIP | string | `""` | Request a specific LoadBalancer address. Deprecated upstream in Kubernetes; most implementations prefer an annotation. Only rendered when non-empty. |
| service.loadBalancerSourceRanges | list | `[]` | Restrict which source CIDRs the LoadBalancer accepts traffic from. |
| service.nodePorts | object | `{"gameTcp":"","gameUdp":"","messaging":""}` | Fixed node ports, used only when `service.type` is `NodePort`. |
| service.type | string | `"LoadBalancer"` | Service type. `LoadBalancer` is the only type that gives players a stable externally routable address without extra plumbing. |
| serviceAccount.annotations | object | `{}` | Annotations for the ServiceAccount. |
| serviceAccount.automountServiceAccountToken | bool | `false` | Mount the ServiceAccount token in the pod. The game server never talks to the Kubernetes API, so this is off by default. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the server pod. |
| serviceAccount.name | string | `""` | Name to use. Generated from the fullname template when empty. |
| sidecars | list | `[]` | Additional containers to run alongside the server. |
| terminationGracePeriodSeconds | int | `60` | Grace period for shutdown. Kubernetes sends SIGTERM here; see docs/troubleshooting.md for how the server handles it and the `lifecycle` hook below if you want to force a SIGINT instead. |
| tolerations | list | `[]` | Tolerations for the server pod. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints for the server pod. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
