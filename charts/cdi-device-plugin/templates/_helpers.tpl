{{- define "cdi-device-plugin.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cdi-device-plugin.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cdi-device-plugin.labels" -}}
app.kubernetes.io/name: {{ include "cdi-device-plugin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "cdi-device-plugin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cdi-device-plugin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
The resource name pods request: explicit if set, otherwise the CDI kind
(everything before the '=' in cdiDevice). Computed here as well as in the
binary so NOTES.txt and any future templating can name it.
*/}}
{{- define "cdi-device-plugin.resourceName" -}}
{{- if .Values.resourceName -}}
{{- .Values.resourceName -}}
{{- else -}}
{{- (splitList "=" .Values.cdiDevice) | first -}}
{{- end -}}
{{- end -}}
