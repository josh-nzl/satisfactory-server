# Networking

## What the server needs

| Port | Protocol | Purpose |
|---|---|---|
| 7777 | TCP | HTTPS API — server management, and the health check |
| 7777 | UDP | Game traffic |
| 8888 | TCP | Messaging |

**All three are required, and all three must be reachable end to end** — through
the Service, through the load balancer, and through your router. Since
Satisfactory 1.1 this includes 8888/TCP; the chart therefore has no switch to
disable it. See the upstream [1.1 upgrade notes][1-1].

[1-1]: https://github.com/wolveix/satisfactory-server/wiki/Upgrading-for-1.1

This is the single most common way a Satisfactory server ends up half-working.
The two symptoms are worth telling apart:

- **Server appears in the list but joining never completes** — 7777/UDP is not
  getting through.
- **Server is reachable but the client reports API connectivity errors** —
  8888/TCP is not getting through.

If you change `server.gamePort` or `server.messagingPort`, the chart moves the
environment variable, the container ports, the Service and the NetworkPolicy
together, so there is only one place to change it.

## The default: one LoadBalancer, mixed protocols

```yaml
service:
  type: LoadBalancer
```

One Service carries all three ports, so players get a single address. Mixed
protocols on a single load balancer went GA in Kubernetes 1.26, which is why
`Chart.yaml` declares that floor.

Most load balancer implementations take their configuration through annotations:

```yaml
service:
  annotations:
    example.com/address-pool: games
  # Some implementations still honour this; most prefer an annotation, and
  # Kubernetes has deprecated the field.
  loadBalancerIP: ""
```

### If your provider rejects mixed protocols

Some cloud load balancers will not put TCP and UDP behind one address. The
workaround is two Services on one IP, which the chart supports through
`extraObjects` rather than by rendering a second Service nobody else needs:

```yaml
service:
  type: LoadBalancer
  annotations:
    example.com/allow-shared-ip: satisfactory

extraObjects:
  - |
    apiVersion: v1
    kind: Service
    metadata:
      name: {{ .Release.Name }}-satisfactory-server-udp
      annotations:
        example.com/allow-shared-ip: satisfactory
    spec:
      type: LoadBalancer
      ports:
        - name: game-udp
          port: 7777
          targetPort: game-udp
          protocol: UDP
      selector:
        app.kubernetes.io/name: satisfactory-server
        app.kubernetes.io/instance: {{ .Release.Name }}
```

You would then remove the UDP port from the main Service. How the two Services
end up sharing one address is provider-specific — that annotation is a
placeholder for whatever yours calls it.

## NodePort

**Read this before choosing NodePort.** The game does not support port
redirection on 7777: the port a player connects to must be the port the server
is listening on. A node port of 30777 forwarding to 7777 does not work — the
server is reachable but joining never completes, exactly like a missing UDP
port.

Kubernetes allocates node ports from 30000-32767 by default, so 7777 is not in
range. NodePort is therefore only usable if you control the API server and can
widen that range to include it:

```
--service-node-port-range=7000-32767
```

With that in place:

```yaml
service:
  type: NodePort
  nodePorts:
    gameTcp: 7777
    gameUdp: 7777
    messaging: 8888
```

Players then connect to any node's address on 7777. Both the TCP and UDP node
ports need forwarding at the router.

If you cannot change the node port range, use `LoadBalancer` or `hostNetwork`
instead. Neither remaps the port, which is the point.

## Host network

```yaml
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
service:
  type: ClusterIP
```

The pod claims 7777 and 8888 directly on whichever node it lands on. Simple, and
avoids a hop, at the cost of pinning the ports on that node and losing them as
cluster-level resources. The chart rejects `hostNetwork` combined with a
`LoadBalancer` Service, since the load balancer would be doing nothing.

Pin the pod to a known node so the address does not move:

```yaml
nodeSelector:
  kubernetes.io/hostname: node-name
```

## ClusterIP and port-forwarding

```yaml
service:
  type: ClusterIP
```

Nothing outside the cluster can reach it. Useful for a server you connect to
over a VPN that already puts you on the cluster network, or for testing.

`kubectl port-forward` will let you check the API responds, but **it only
carries TCP**, so you cannot actually join a game through it.

## Preserving client addresses

```yaml
service:
  externalTrafficPolicy: Local
```

`Cluster` (the default) may hop through a second node, and the server sees the
node address rather than the player's. `Local` avoids the hop and preserves the
source address, but only routes to nodes actually running the pod — with one
replica, that is exactly one node. Whether your load balancer handles that
correctly depends on the implementation.

## Certificates for the HTTPS API

Given no certificate, the server generates a self-signed one on first start and
stores it in `ServerSettings.<port>.sav`. Everything works; players just get a
certificate warning when they join. Supplying your own removes it:

```yaml
tls:
  enabled: true
  existingSecret: satisfactory-tls
```

The Secret holds the certificate under `tls.crt` and the key under `tls.key` —
the layout cert-manager already produces, so its Secrets work untouched. Point
`tls.certKey` and `tls.keyKey` elsewhere if yours differ.

**The certificate must name the exact host players type into the join box.**
Satisfactory does strict hostname verification and does not accept wildcards, so
a `*.example.com` certificate fails even for `play.example.com`. If players join
by IP, that IP has to be a SAN. Get this wrong and the client reports
`Failed to connect to server API` with nothing in the server log to say why —
budget for that, because it looks exactly like a firewall problem.

That constraint also means a public CA and DNS-01: the server has nothing
listening on port 80, so HTTP-01 cannot validate. A private CA works for a LAN
server, but every player then has to trust it, which is usually more work than
the warning is worth.

The chart deliberately does not create the certificate. To have Helm manage one
anyway, put a cert-manager `Certificate` in `extraObjects` and name its
`secretName` here.

### Renewal

The server reads the files once, at start. A renewed certificate therefore does
nothing until the pod restarts, and the chart does not restart it for you —
rolling the pod disconnects everyone mid-game, which is not a thing to do
silently on cert-manager's schedule. Restart it when it suits you:

```console
kubectl rollout restart deployment/my-server-satisfactory-server
```

If you would rather it were automatic, [Reloader][reloader] does it from a pod
annotation. Deliberately not wired in by default.

[reloader]: https://github.com/stakater/Reloader

## Firewall and router

For a server reachable from the internet, forward to whatever address the
Service ends up on:

- 7777/TCP
- 7777/UDP
- 8888/TCP

All three, not a subset. If you changed `server.gamePort` or
`server.messagingPort`, forward those instead.

## NetworkPolicy

Off by default. When enabled it allows the game ports from
`networkPolicy.allowedSourceRanges` and manages egress:

```yaml
networkPolicy:
  enabled: true
  allowedSourceRanges:
    - 0.0.0.0/0
  egress:
    enabled: true
```

Egress needs care. **The server contacts Steam on every start to update the
game, and that failing does not degrade gracefully — the container exits.** The
default egress rule allows the internet while excluding RFC1918 ranges, so a
compromised game server cannot reach the rest of your network, and separately
allows DNS to the cluster resolver.

If you would rather not manage egress at all:

```yaml
networkPolicy:
  enabled: true
  egress:
    enabled: false
```

A restrictive egress policy is workable alongside `server.skipUpdate: true`, but
then you are responsible for updating the game yourself, and a client running a
newer build will not be able to connect.
