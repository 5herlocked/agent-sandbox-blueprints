{{/* Same capability labels as the Lambda chart; component identifies the substrate. */}}
{{- define "agentcore.labels" -}}
app.kubernetes.io/name: agent-sandbox
app.kubernetes.io/component: agentcore
app.kubernetes.io/part-of: open-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "agentcore.namespace" -}}
{{- default "agent-sandbox-system" .Values.namespace -}}
{{- end -}}

{{/* AgentRuntime names require an initial letter, then only letters/digits/_;
     the _dark_factory suffix consumes 13 of the 48 permitted characters. */}}
{{- define "agentcore.runtimeStem" -}}
{{- $cluster := .Values.agentcore.podIdentity.clusterName -}}
{{- if not (regexMatch "^[A-Za-z]" $cluster) -}}
{{- fail "agentcore.podIdentity.clusterName must start with a letter (AgentRuntime naming rule)" -}}
{{- end -}}
{{- $safe := regexReplaceAll "[^A-Za-z0-9_]" $cluster "_" -}}
{{- if gt (len $safe) 35 -}}
{{- printf "%s_%s" (trunc 26 $safe) (sha256sum $cluster | trunc 8) -}}
{{- else -}}
{{- $safe -}}
{{- end -}}
{{- end -}}
