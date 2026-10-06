{{- define "tazama-workload.name" -}}
{{- default .Values.name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tazama-workload.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "tazama-workload.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "tazama-workload.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tazama
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "tazama-workload.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tazama-workload.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "tazama-workload.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "tazama-workload.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "tazama-workload.affinity" -}}
{{- if .Values.workerOnly }}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
            - key: node-role.kubernetes.io/master
              operator: DoesNotExist
{{- else if .Values.affinity }}
affinity:
{{ toYaml .Values.affinity | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "tazama-workload.initContainers" -}}
{{- if .Values.startupChecks.enabled }}
initContainers:
{{- if .Values.startupChecks.postgres }}
  - name: wait-db
    image: {{ .Values.startupChecks.postgresImage | quote }}
    imagePullPolicy: IfNotPresent
    env:
      - name: PGUSER
        valueFrom:
          secretKeyRef:
            name: {{ .Values.credentialsSecretName }}
            key: {{ .Values.postgresUserKey }}
      - name: PGPASSWORD
        valueFrom:
          secretKeyRef:
            name: {{ .Values.credentialsSecretName }}
            key: {{ .Values.postgresPasswordKey }}
    command: ["sh", "-c"]
    args:
      - >
        until psql -h {{ .Values.hosts.postgresql }} -U "$PGUSER"
        -d {{ .Values.startupChecks.schemaDatabase }}
        -c "SELECT '{{ .Values.startupChecks.schemaTable }}'::regclass;"
        >/dev/null 2>&1; do echo "waiting for postgres schema"; sleep 2; done
{{- end }}
{{- if .Values.startupChecks.valkey }}
  - name: wait-valkey
    image: {{ .Values.startupChecks.busyboxImage | quote }}
    command: ["sh", "-c"]
    args:
      - until nc -z {{ .Values.hosts.valkey }} 6379; do echo "waiting for valkey"; sleep 2; done
{{- end }}
{{- if .Values.startupChecks.nats }}
  - name: wait-nats
    image: {{ .Values.startupChecks.busyboxImage | quote }}
    command: ["sh", "-c"]
    args:
      - until nc -z {{ .Values.hosts.nats }} 4222; do echo "waiting for nats"; sleep 2; done
{{- end }}
{{- end }}
{{- end -}}
