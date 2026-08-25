{{/* Expand the chart name. */}}
{{- define "tazama.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name. */}}
{{- define "tazama.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Chart label value. */}}
{{- define "tazama.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Namespace helper. */}}
{{- define "tazama.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "tazama.labels" -}}
helm.sh/chart: {{ include "tazama.chart" . }}
{{ include "tazama.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "tazama.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tazama.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Service account name. */}}
{{- define "tazama.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "tazama.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Resolve a service/component image tag; default to global Tazama version when empty. */}}
{{- define "tazama.imageTag" -}}
{{- $tag := .tag | default "" -}}
{{- if $tag -}}
{{- $tag -}}
{{- else -}}
{{- $.root.Values.global.tazamaVersion -}}
{{- end -}}
{{- end -}}

{{/* Render an image reference with an optional registry prefix. */}}
{{- define "tazama.image" -}}
{{- $root := .root -}}
{{- $repository := .repository -}}
{{- $tag := include "tazama.imageTag" (dict "root" $root "tag" .tag) -}}
{{- $registry := $root.Values.global.imageRegistry | default "" -}}
{{- if $registry -}}
{{ printf "%s/%s:%s" $registry $repository $tag }}
{{- else -}}
{{ printf "%s:%s" $repository $tag }}
{{- end -}}
{{- end -}}

{{/* Generic component fullname helper. */}}
{{- define "tazama.componentname" -}}
{{- printf "%s-%s" (include "tazama.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Standard metadata block for namespaced objects. */}}
{{- define "tazama.metadata" -}}
name: {{ include "tazama.componentname" (dict "root" .root "name" .name) }}
namespace: {{ include "tazama.namespace" .root }}
labels:
  {{- include "tazama.labels" .root | nindent 2 }}
{{- end -}}

{{/* Common pod annotations. */}}
{{- define "tazama.podAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Shared image pull secrets block. */}}
{{- define "tazama.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Shared service account wiring. */}}
{{- define "tazama.serviceAccount" -}}
serviceAccountName: {{ include "tazama.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
{{- end -}}

{{/* Shared pod-level settings. */}}
{{- define "tazama.podSpec" -}}
{{ include "tazama.imagePullSecrets" . }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{ include "tazama.serviceAccount" . }}
{{- if .Values.scheduling.workerOnly }}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
            - key: node-role.kubernetes.io/master
              operator: DoesNotExist
{{- end }}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Wait for core infrastructure and the initialized schema before app start. */}}
{{- define "tazama.coreDependencyInitContainers" -}}
{{- if .Values.global.startupChecks.enabled }}
initContainers:
  - name: wait-db
    image: {{ .Values.global.startupChecks.postgresImage | quote }}
    env:
      - name: PGUSER
        valueFrom:
          secretKeyRef:
            name: {{ include "tazama.credentialsSecretName" . }}
            key: POSTGRES_USER
      - name: PGPASSWORD
        valueFrom:
          secretKeyRef:
            name: {{ include "tazama.credentialsSecretName" . }}
            key: POSTGRES_PASSWORD
    command: ["sh", "-c"]
    args:
      - >-
        until psql -h {{ include "tazama.core.postgresHost" . }} -U "$PGUSER"
        -d {{ .Values.global.startupChecks.schemaDatabase }}
        -c "SELECT '{{ .Values.global.startupChecks.schemaTable }}'::regclass;"
        >/dev/null 2>&1; do sleep 2; done
  - name: wait-valkey
    image: {{ .Values.global.startupChecks.busyboxImage | quote }}
    command: ["sh", "-c"]
    args:
      - until nc -z {{ include "tazama.core.valkeyHost" . }} 6379; do sleep 2; done;
  - name: wait-nats
    image: {{ .Values.global.startupChecks.busyboxImage | quote }}
    command: ["sh", "-c"]
    args:
      - until nc -z {{ include "tazama.core.natsHost" . }} 4222; do sleep 2; done;
{{- end }}
{{- end }}

{{/* Shared container-level settings. */}}
{{- define "tazama.containerSecurityContext" -}}
securityContext:
  {{- toYaml .Values.securityContext | nindent 2 }}
{{- end -}}

{{/* Shared envFrom refs for the global env plus an optional component env configmap. */}}
{{- define "tazama.envFrom" -}}
{{- $component := .component | default "" -}}
envFrom:
  - configMapRef:
      name: {{ include "tazama.componentname" (dict "root" .root "name" "global-env") }}
{{- if $component }}
  - configMapRef:
      name: {{ include "tazama.componentname" (dict "root" .root "name" $component) }}
{{- end }}
{{- end -}}

{{/* Shared secret name. */}}
{{- define "tazama.credentialsSecretName" -}}
{{ include "tazama.componentname" (dict "root" . "name" "credentials") }}
{{- end -}}

{{/* Merge two maps and render as env vars. */}}
{{- define "tazama.renderEnvMap" -}}
{{- $env := .env | default dict -}}
{{- range $k, $v := $env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end -}}
{{- end -}}

{{/* Convenience names for shared infrastructure endpoints. */}}
{{- define "tazama.core.postgresHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "core-postgres") }}
{{- end -}}

{{- define "tazama.core.natsHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "core-nats") }}
{{- end -}}

{{- define "tazama.core.valkeyHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "core-valkey") }}
{{- end -}}

{{- define "tazama.extensions.postgresHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "extensions-postgres") }}
{{- end -}}

{{- define "tazama.extensions.sftpHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "extensions-sftp") }}
{{- end -}}

{{- define "tazama.extensions.couchdbHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "extensions-couchdb") }}
{{- end -}}

{{- define "tazama.extensions.flowableHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "extensions-flowable") }}
{{- end -}}

{{- define "tazama.extensions.opensearchHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "extensions-opensearch") }}
{{- end -}}

{{- define "tazama.biar.tikaHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-tika") }}
{{- end -}}

{{- define "tazama.biar.solrHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-solr") }}
{{- end -}}

{{- define "tazama.biar.nifiHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-nifi") }}
{{- end -}}

{{- define "tazama.biar.scmHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-scm") }}
{{- end -}}

{{- define "tazama.biar.omHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-om") }}
{{- end -}}

{{- define "tazama.biar.reconHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-recon") }}
{{- end -}}

{{- define "tazama.biar.s3gHost" -}}
{{ include "tazama.componentname" (dict "root" . "name" "biar-s3g") }}
{{- end -}}

{{/* Resolve a full ingress host from an ingress host entry. */}}
{{- define "tazama.ingressHost" -}}
{{- $root := .root -}}
{{- $entry := .entry -}}
{{- if ($entry.host | default "") -}}
{{- $entry.host -}}
{{- else if and ($entry.subdomain | default "") ($root.Values.ingress.domain | default "") -}}
{{- printf "%s.%s" $entry.subdomain $root.Values.ingress.domain -}}
{{- end -}}
{{- end -}}

{{/* Resolve the ingress host configured for a specific chart service suffix, if present. */}}
{{- define "tazama.ingressHostForService" -}}
{{- $root := .root -}}
{{- $service := .service -}}
{{- $host := "" -}}
{{- range $entry := $root.Values.ingress.hosts }}
  {{- if and (eq ($entry.service | default "") $service) (eq $host "") }}
    {{- $host = (include "tazama.ingressHost" (dict "root" $root "entry" $entry)) -}}
  {{- end }}
{{- end }}
{{- $host -}}
{{- end -}}

{{/* Resolve a public URL for a service using ingress scheme + host, with an optional path suffix. */}}
{{- define "tazama.publicUrlForService" -}}
{{- $root := .root -}}
{{- $service := .service -}}
{{- $path := .path | default "" -}}
{{- $host := include "tazama.ingressHostForService" (dict "root" $root "service" $service) -}}
{{- if $host -}}
{{- printf "%s://%s%s" ($root.Values.ingress.scheme | default "http") $host $path -}}
{{- end -}}
{{- end -}}
