{{/*
Helpers of this chart (raulstechtips). The upstream helper is in _helpers.tpl.
*/}}

{{/* Common labels for the objects that this chart adds (not the upstream Tenant). */}}
{{- define "minio.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* The Tenant name. Other names are calculated from it. */}}
{{- define "minio.tenantName" -}}
{{- required "tenant.name is required" .Values.tenant.name -}}
{{- end -}}

{{/* Name of the Secret with config.env: tenant.configSecret.name, else "<tenant>-minio-env-configuration". */}}
{{- define "minio.configSecretName" -}}
{{- .Values.tenant.configSecret.name | default (printf "%s-minio-env-configuration" (include "minio.tenantName" .)) -}}
{{- end -}}

{{/* Name of the TLS Secret that cert-manager writes for the chart certificate. */}}
{{- define "minio.tlsSecretName" -}}
{{- printf "%s-minio-tls" (include "minio.tenantName" .) -}}
{{- end -}}

{{/*
Tenant externalCertSecret as a YAML list. tenant.certificate.externalCertSecret wins when it is set.
Else: the chart certificate (when tls.enabled), then each name in tls.externalCertSecrets.
*/}}
{{- define "minio.externalCertSecrets" -}}
{{- $upstream := .Values.tenant.certificate.externalCertSecret | default list -}}
{{- if $upstream -}}
{{- toYaml $upstream -}}
{{- else -}}
{{- $out := list -}}
{{- if .Values.tls.enabled -}}
{{- $out = append $out (dict "name" (include "minio.tlsSecretName" .) "type" "kubernetes.io/tls") -}}
{{- end -}}
{{- range .Values.tls.externalCertSecrets -}}
{{- $out = append $out (dict "name" . "type" "kubernetes.io/tls") -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}

{{/*
Tenant features.domains as YAML. tenant.features.domains wins when it is set.
Else: console = https://<ingressRoute.console.host>, minio = [https://<first ingressRoute.api.hosts host>].
Only the first api host is a Tenant domain: MinIO uses it as MINIO_SERVER_URL (see DEVSECOPS-181).
*/}}
{{- define "minio.domains" -}}
{{- $upstream := .Values.tenant.features.domains | default dict -}}
{{- if $upstream -}}
{{- toYaml $upstream -}}
{{- else -}}
{{- $out := dict -}}
{{- with .Values.ingressRoute.console.host -}}
{{- $_ := set $out "console" (printf "https://%s" .) -}}
{{- end -}}
{{- with .Values.ingressRoute.api.hosts -}}
{{- $_ := set $out "minio" (list (printf "https://%s" (first .).host)) -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Default pool anti-affinity: required, one pod per node, for this tenant's pods. It selects
v1.min.io/tenant, the label that the operator puts on every Tenant pod (the StatefulSet template
has no app.kubernetes.io/instance label).
*/}}
{{- define "minio.poolAffinity" -}}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
          - key: v1.min.io/tenant
            operator: In
            values:
              - {{ include "minio.tenantName" . }}
      topologyKey: kubernetes.io/hostname
{{- end -}}

{{/*
One IngressRoute. Arguments: dict "root" $ "name" <object name> "host" <entry> "service" <name>
"port" <port>. The entry may override entryPoints, ingressClass, middlewares and tlsSecretName.
*/}}
{{- define "minio.ingressRoute" -}}
{{- $root := .root -}}
{{- $d := $root.Values.ingressRoute -}}
{{- $h := .host -}}
{{- $middlewares := $d.middlewares -}}
{{- if hasKey $h "middlewares" }}{{ $middlewares = $h.middlewares }}{{ end -}}
{{- $tls := $h.tlsSecretName | default $d.tlsSecretName -}}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "minio.labels" $root | nindent 4 }}
  annotations:
    kubernetes.io/ingress.class: {{ $h.ingressClass | default $d.ingressClass | quote }}
spec:
  entryPoints:
    {{- toYaml ($h.entryPoints | default $d.entryPoints) | nindent 4 }}
  routes:
    - match: {{ printf "Host(`%s`)" (required (printf "host is required for IngressRoute %s" .name) $h.host) | quote }}
      kind: Rule
      {{- with $middlewares }}
      middlewares:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      services:
        - name: {{ .service }}
          port: {{ .port }}
  tls:
    secretName: {{ required (printf "tlsSecretName is required for IngressRoute %s (set ingressRoute.tlsSecretName or the tlsSecretName of the host)" .name) $tls | quote }}
{{- end -}}
