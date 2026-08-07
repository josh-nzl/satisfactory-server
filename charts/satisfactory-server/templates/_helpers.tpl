{{/*
Chart name, truncated to the 63 character label limit.
*/}}
{{- define "satisfactory-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "satisfactory-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "satisfactory-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "satisfactory-server.labels" -}}
helm.sh/chart: {{ include "satisfactory-server.chart" . }}
{{ include "satisfactory-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "satisfactory-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "satisfactory-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "satisfactory-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "satisfactory-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "satisfactory-server.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/*
Names of the two claims, so the Deployment and the PVC templates cannot drift.
*/}}
{{- define "satisfactory-server.configClaimName" -}}
{{- default (printf "%s-config" (include "satisfactory-server.fullname" .)) .Values.persistence.config.existingClaim }}
{{- end }}

{{- define "satisfactory-server.gamefilesClaimName" -}}
{{- default (printf "%s-gamefiles" (include "satisfactory-server.fullname" .)) .Values.persistence.gamefiles.existingClaim }}
{{- end }}

{{/*
Security context IDs, resolved with an explicit nil check rather than `default`.

`default` cannot distinguish 0 from unset, and 0 is exactly the value that means
"run as root" here -- `runAsUser: 0 | default 1000` silently yields 1000, which
would route the root configuration down the non-root path.
*/}}
{{- define "satisfactory-server.runAsUser" -}}
{{- if kindIs "invalid" .Values.podSecurityContext.runAsUser -}}1000{{- else -}}{{- .Values.podSecurityContext.runAsUser | int -}}{{- end -}}
{{- end }}

{{- define "satisfactory-server.runAsGroup" -}}
{{- if kindIs "invalid" .Values.podSecurityContext.runAsGroup -}}1000{{- else -}}{{- .Values.podSecurityContext.runAsGroup | int -}}{{- end -}}
{{- end }}

{{- define "satisfactory-server.fsGroup" -}}
{{- if kindIs "invalid" .Values.podSecurityContext.fsGroup -}}1000{{- else -}}{{- .Values.podSecurityContext.fsGroup | int -}}{{- end -}}
{{- end }}

{{/*
PUID/PGID.

These are never independent knobs. The image's entrypoint compares the UID it is
running as against the `steam` user baked into the image, so a security context
and an environment that disagree produce a container that exits immediately.
Deriving them from the security context removes that whole class of bug.

Running as root is the one case where they legitimately differ: the entrypoint
chowns to PUID:PGID and then drops to that user, so the IDs come from fsGroup
instead, keeping the on-disk ownership and the runtime user consistent.
*/}}
{{- define "satisfactory-server.puid" -}}
{{- if and (not (kindIs "invalid" .Values.puid)) (ne (toString .Values.puid) "") -}}
{{- .Values.puid | int -}}
{{- else if eq (include "satisfactory-server.runAsUser" . | int) 0 -}}
{{- include "satisfactory-server.fsGroup" . -}}
{{- else -}}
{{- include "satisfactory-server.runAsUser" . -}}
{{- end -}}
{{- end }}

{{- define "satisfactory-server.pgid" -}}
{{- if and (not (kindIs "invalid" .Values.pgid)) (ne (toString .Values.pgid) "") -}}
{{- .Values.pgid | int -}}
{{- else if eq (include "satisfactory-server.runAsUser" . | int) 0 -}}
{{- include "satisfactory-server.fsGroup" . -}}
{{- else -}}
{{- include "satisfactory-server.runAsGroup" . -}}
{{- end -}}
{{- end }}

{{/*
Fail the render on the configurations that would otherwise produce a pod that
CrashLoops with an error only visible in the container log.
*/}}
{{- define "satisfactory-server.validate" -}}
{{- $uid := include "satisfactory-server.runAsUser" . | int -}}
{{- $gid := include "satisfactory-server.runAsGroup" . | int -}}
{{- if and (ne $uid 0) (ne $uid 1000) -}}
{{- fail (printf "podSecurityContext.runAsUser is %d, which the wolveix/satisfactory-server image cannot run as. Its entrypoint only fixes ownership when running as root (runAsUser: 0); as any other user it requires the UID to match the 'steam' user built into the image (1000) and exits otherwise. Use 1000, or 0 with the extra capabilities described in docs/configuration.md." $uid) -}}
{{- end -}}
{{- /* The entrypoint's non-root guard tests the GID as well as the UID. */ -}}
{{- if and (ne $uid 0) (ne $gid 1000) -}}
{{- fail (printf "podSecurityContext.runAsGroup is %d. When not running as root the image requires the GID to match the 'steam' group built into the image (1000), not only the UID, and exits on start otherwise. Use 1000, or run as root." $gid) -}}
{{- end -}}
{{- if and (eq $uid 0) .Values.podSecurityContext.runAsNonRoot -}}
{{- fail "podSecurityContext.runAsUser is 0 but runAsNonRoot is true; the kubelet will refuse to start the container. Set runAsNonRoot: false when running as root." -}}
{{- end -}}
{{- if and (ne $uid 0) (ne (include "satisfactory-server.puid" . | int) $uid) -}}
{{- fail (printf "puid (%s) does not match podSecurityContext.runAsUser (%d). When not running as root the image requires them to be the same, and will exit on start if they are not." (include "satisfactory-server.puid" .) $uid) -}}
{{- end -}}
{{- /* The entrypoint treats PUID or PGID of 0 as a fatal error, whatever it is
       running as, so catch it here rather than at container start. */ -}}
{{- if eq (include "satisfactory-server.puid" . | int) 0 -}}
{{- fail "The resolved PUID is 0. The image refuses to run the server as root and will exit. When running as root, set podSecurityContext.fsGroup (or puid) to the non-root UID the server should drop to." -}}
{{- end -}}
{{- if eq (include "satisfactory-server.pgid" . | int) 0 -}}
{{- fail "The resolved PGID is 0. The image refuses to run the server as the root group and will exit. When running as root, set podSecurityContext.fsGroup (or pgid) to the non-root GID the server should drop to." -}}
{{- end -}}
{{- if and .Values.hostNetwork (eq .Values.service.type "LoadBalancer") -}}
{{- fail "hostNetwork is enabled together with service.type LoadBalancer. Pick one: hostNetwork claims the ports directly on the node and makes the LoadBalancer redundant. Use service.type ClusterIP alongside hostNetwork." -}}
{{- end -}}
{{- end }}

{{/*
The image ships its own health check, which POSTs a HealthCheck call to the
server's HTTPS API on SERVERGAMEPORT. Using it means the probe follows the game
port automatically. Call with a dict: {"ctx": $, "probe": .Values.probes.startup}
*/}}
{{- define "satisfactory-server.probe" -}}
exec:
  command:
    - /bin/bash
    - /home/steam/healthcheck.sh
initialDelaySeconds: {{ .probe.initialDelaySeconds | default 0 }}
periodSeconds: {{ .probe.periodSeconds | default 15 }}
timeoutSeconds: {{ .probe.timeoutSeconds | default 10 }}
failureThreshold: {{ .probe.failureThreshold | default 3 }}
successThreshold: {{ .probe.successThreshold | default 1 }}
{{- end }}

{{/*
Environment for the server container. The server.* block renders first and
extraEnv second, so a user-supplied entry wins on duplicate names -- that is the
escape hatch for any variable the image gains before this chart catches up.
*/}}
{{- define "satisfactory-server.env" -}}
- name: PUID
  value: {{ include "satisfactory-server.puid" . | quote }}
- name: PGID
  value: {{ include "satisfactory-server.pgid" . | quote }}
{{- /*
Numbers go through int64 before quoting. YAML decodes them as float64, and
quoting a float64 of 2162688 yields "2.162688e+06", which the server rejects.
*/}}
- name: MAXPLAYERS
  value: {{ .Values.server.maxPlayers | int64 | quote }}
- name: MAXTICKRATE
  value: {{ .Values.server.maxTickRate | int64 | quote }}
- name: MAXOBJECTS
  value: {{ .Values.server.maxObjects | int64 | quote }}
- name: AUTOSAVENUM
  value: {{ .Values.server.autosaveNum | int64 | quote }}
- name: SERVERSTREAMING
  value: {{ .Values.server.serverStreaming | quote }}
- name: DISABLESEASONALEVENTS
  value: {{ .Values.server.disableSeasonalEvents | quote }}
- name: SKIPUPDATE
  value: {{ .Values.server.skipUpdate | quote }}
- name: TIMEOUT
  value: {{ .Values.server.timeout | int64 | quote }}
- name: MULTIHOME
  value: {{ .Values.server.multihome | quote }}
- name: DEBUG
  value: {{ .Values.server.debug | quote }}
- name: LOG
  value: {{ .Values.server.log | quote }}
- name: VMOVERRIDE
  value: {{ .Values.server.vmOverride | quote }}
- name: SERVERGAMEPORT
  value: {{ .Values.server.gamePort | int64 | quote }}
- name: SERVERMESSAGINGPORT
  value: {{ .Values.server.messagingPort | int64 | quote }}
- name: STEAMBETA
  value: {{ .Values.server.beta.enabled | quote }}
{{- if .Values.server.beta.id }}
- name: STEAMBETAID
  value: {{ .Values.server.beta.id | quote }}
{{- end }}
{{- if .Values.server.beta.key }}
- name: STEAMBETAKEY
  value: {{ .Values.server.beta.key | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
