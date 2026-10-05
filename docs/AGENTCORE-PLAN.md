# Plan: Amazon Bedrock AgentCore Runtime as a third substrate

> **Status:** IMPLEMENTED (units A–F); live verification (§7 items 3–6) pending.
> Design rule for this work: add a substrate, do not change the existing two.
> Every new file is a sibling of an existing Kata or Lambda file and follows its
> shape. The only shared files that change are the Sensor and `iterate.js`.

## 1. What this adds

Two substrate entries, one working and one placeholder:

| Substrate | Label | WorkflowTemplate | Status |
|---|---|---|---|
| AgentCore Runtime, microVM compute (**ACR**) | `darkfactory-agentcore` | `df-run-agentcore` | Build now |
| AgentCore Runtime Instances (**ACRI**) | `darkfactory-agentcore-instances` | — | Placeholder. Blocked on ACK; see §9 |

The pipeline, review gates, holdout, security and DevOps agents, iterate loop,
merge path, and the shared coder image are reused as they are. The AgentCore
container runs the same `examples/_shared/agent/entrypoint.js` that Kata and
Lambda run.

## 2. Why this fits the existing seam

The contract between pipeline and substrate is not shell access and not a
`SandboxClaim`. It is (see `examples/_shared/templates/10-rbac.yaml:1-9`, no
`pod/exec`):

1. Start the coder with `DF_*` env, a GitHub token file, a writable `WORKSPACE`,
   and a model path.
2. The coder clones, implements, tests, pushes `df/issue-N`, opens the PR, and
   sets the `dark-factory/implementation` commit status
   (`examples/_shared/agent/entrypoint.js:394-546`).
3. The workflow polls GitHub for that PR (`await-coder`), then runs the gates.
4. The substrate ends or parks its compute.

Only two templates per run WorkflowTemplate are substrate-specific: the
launch step and the power/exit step. In `df-run-lambda` these are
`provision-microvm` (`examples/dark-factory-lambda/templates/23-workflowtemplate-df-run-lambda.yaml:218-329`)
and `set-microvm-power` / `teardown` (same file, `:900-945`). AgentCore
replaces those two with `invoke-agentcore` and `stop-agentcore-session`.

## 3. Decisions

| Topic | Decision | Reason |
|---|---|---|
| Inference | `USE_BEDROCK=1`, direct Bedrock through the runtime execution role. Network mode `PUBLIC`. | Matches Lambda MicroVM, the existing out-of-cluster substrate (`lambda-microvm/templates/kro-rgd/10-rgd-and-image.yaml:111-133`). A VM outside the cluster cannot reach Bifrost's ClusterIP. `entrypoint.js` already supports this path. |
| Resource creation | Managed ACK's bundled `bedrockagentcorecontrol` controller + a KRO `ResourceGraphDefinition`, deployed by ArgoCD. No self-managed controller (live finding: Managed ACK already ships it). | Same mechanism as `lambda-microvm/` minus the self-managed controller. No Terraform, CDK, or CLI for runtime resources. |
| Session model | Disposable per round. `runtimeSessionId` = Argo `workflow.uid`. `StopRuntimeSession` after `await-coder` succeeds. Fix rounds start a new session; the coder re-clones `df/issue-N` (`entrypoint.js:165-184`). | GitHub holds the branch, the issue, and the feedback. AgentCore microVM cold start is seconds, so there is nothing to gain from suspend/resume. No `sessionStorage`. |
| Gate templates | Copied into `df-run-agentcore`, same as the two existing templates. | Zero edits to Kata and Lambda WorkflowTemplates. Deduplication to `templateRef` stays a separate roadmap item. |
| HTTP host | New `agentcore/image/host.js`. Not shared with `lambda-microvm/image/hook-server.js`. | Lambda image stays byte-identical. |
| Values | Fourth `defaults.yaml` copy. | Consistent with the other examples. ROADMAP gap #6 (consolidation) stays open. |
| ACRI | Placeholder README + ROADMAP entry. | ACK v1.15.1 has no `CapacityProvider` CRD and no `capacityProviderConfiguration` on `AgentRuntime`. |
| Platform version | **V2** (snapshot-based cold start). Set by a one-shot, idempotent `update-agent-runtime --platform-version V2` in `task agentcore`, after the ACK-created runtime reaches `READY`. Value `agentcore.platformVersion` defaults to `V2`. | ACK v1.15.1 pins SDK `bedrockagentcorecontrol v1.47.0`, which predates `platformVersion`; the CRD cannot carry it. ACK omits the field on later updates, and the API keeps the current platform version when the field is omitted, so there is no drift fight. Same ACK model bump unblocks this and ACRI. |
| Network variants | Two KRO instances from one RGD, selected by `agentcore.network.mode`: `public` (`networkMode: PUBLIC`) and `vpc` (`networkMode: VPC`, private subnets + egress-only security group from Terraform). Default `public`. | Shardul asked for both. VPC mode gives private egress through the existing NAT and keeps the option of reaching in-cluster services later. Inference stays direct Bedrock in both. |

## 4. Runtime flow

```text
label darkfactory-agentcore
  → EventSource/Sensor (shared)           third dependency + trigger
  → df-run-agentcore
      invoke-agentcore      aws bedrock-agentcore invoke-agent-runtime
                              --runtime-session-id {{workflow.uid}}
                              --payload '{issueNumber, repo, branch, baseBranch,
                                          issueTitle, iterateNoteB64, ghToken}'
                            host.js writes token file, spawns entrypoint.js,
                            returns 202 within seconds
      await-coder           shared GitHub poller (copied)
      stop-agentcore-session aws bedrock-agentcore stop-runtime-session (advisory)
      gates                 holdout / devops / security / deploy-test / sticky-status (copied)
  onExit: stop-agentcore-session again, idempotent, guards a failed run

PR comment "fix ..." → df-iterate (shared) → df-run-agentcore, fresh session
PR approved          → df-merge-teardown (shared), nothing AgentCore-specific to delete
```

The session stays alive between invoke and stop because `host.js` answers
`GET /ping` with `HealthyBusy` while the coder child runs. AgentCore treats a
`HealthyBusy` session as not idle, so `idleRuntimeSessionTimeout` does not end it
mid-run. `maxLifetime` (default 28800 s) is the final backstop.

## 5. New artifacts

### 5.1 `agentcore/` — the substrate (ArgoCD, GitOps)

Mirrors `lambda-microvm/`.

| File | Mirrors | Content |
|---|---|---|
| `agentcore/README.md` | `lambda-microvm/README.md` | What it is, prerequisites, image build, how to verify |
| `agentcore/Chart.yaml`, `values.yaml`, `templates/_helpers.tpl` | same in `lambda-microvm/` | Chart scaffolding, `agentcore.enabled` gate |
| ~~`agentcore/bootstrap/00-ack-controller.yaml`~~ | — | **Dropped after live verification.** Managed ACK (capability 46.184.0) already bundles the `bedrockagentcorecontrol` controller; a self-managed copy fought it over the same `AgentRuntime`. The capability role gets the `bedrock-agentcore:*AgentRuntime*` grants in `capabilities.tf` instead. |
| `agentcore/bootstrap/10-substrate.yaml` | `lambda-microvm/bootstrap/10-substrate.yaml` | ArgoCD Application, wave 1: this chart with `accountId`, `clusterName`, `image.uri` |
| ~~`agentcore/templates/iam/00-controller-pod-identity.yaml`~~ | — | **Dropped** with the controller above. |
| `agentcore/templates/iam/10-invoker-pod-identity.yaml` | `examples/_shared/templates/10-rbac.yaml:118-138` | ACK `iam` Role `<cluster>-dark-factory-agentcore-invoker` (policy: `bedrock-agentcore:InvokeAgentRuntime`, `bedrock-agentcore:StopRuntimeSession` on the runtime ARN) + PodIdentityAssociation to SA `dark-factory-agentcore` in the Argo namespace |
| `agentcore/templates/iam/40-kro-graph-rbac.yaml` | `lambda-microvm/templates/iam/40-kro-graph-rbac.yaml` | KRO RBAC for `agentruntimes.bedrockagentcorecontrol.services.k8s.aws` and `roles.iam.services.k8s.aws` |
| `agentcore/templates/kro-rgd/10-rgd.yaml` | `lambda-microvm/templates/kro-rgd/10-rgd-and-image.yaml` | RGD `AgentCoreSandbox` (`kro.run`, wave -1) + one instance (wave 0). See §5.2 |
| `agentcore/image/Dockerfile` | `lambda-microvm/image/Dockerfile` | `FROM <ecr>/coder:arm64`, `COPY host.js /app/host.js`, `CMD ["node","/app/host.js"]`, `EXPOSE 8080` |
| `agentcore/image/host.js` | `lambda-microvm/image/hook-server.js` | See §5.3 |
| `agentcore/image/publish.sh` | `lambda-microvm/image/publish.sh` | `docker buildx build --platform linux/arm64`, push to ECR, print digest |

A dedicated ServiceAccount is required. EKS Pod Identity allows one association
per ServiceAccount, and `dark-factory-workflow` is already bound to the Lambda
controller role when that substrate is enabled. `df-run-agentcore` sets
`serviceAccountName: dark-factory-agentcore` on the `invoke-agentcore` and
`stop-agentcore-session` templates only; all other steps keep
`dark-factory-workflow`. The example chart adds the SA and a RoleBinding to the
existing `dark-factory-workflow` Role (executor needs `workflowtaskresults`).

### 5.2 KRO graph `AgentCoreSandbox`

Schema (platform-owned, set once):

```yaml
spec:
  name: string                 # <cluster>; prefix for role + runtime names (48-char limit on runtime name)
  image: { uri: string }       # ECR image URI pinned to a digest
  region: string
  network:
    mode: string | default=PUBLIC          # PUBLIC | VPC
    subnets: []string | default=[]         # VPC mode only; private subnet IDs from terraform output
    securityGroups: []string | default=[]  # VPC mode only; egress-only SG from terraform output
  lifecycle:
    idleRuntimeSessionTimeout: integer | default=900
    maxLifetime: integer | default=28800
status:
  runtimeARN: ${runtime.status.ackResourceMetadata.arn}
  runtimeID: ${runtime.status.agentRuntimeID}
  runtimeStatus: ${runtime.status.status}
  executionRoleARN: ${execRole.status.ackResourceMetadata.arn}
```

The chart renders one `AgentCoreSandbox` instance. `agentcore.network.mode`
selects `PUBLIC` or `VPC`; in `VPC` mode the instance carries
`network.subnets` and `network.securityGroups`, which `task agentcore` reads
from `terraform output` and injects the same way it injects `accountId`. The
RGD sets `networkConfiguration.networkModeConfig` only when `mode == VPC`
(KRO `includeWhen` or a CEL conditional on the field).

VPC mode prerequisites (Terraform, behind `enable_agentcore_vpc`): output
`private_subnet_ids`, and `aws_security_group.agentcore` with egress-only
rules; output `agentcore_security_group_id`. AgentCore VPC mode requires
subnets in supported AZs; the README records this check.

Resources:

1. `execRole` — ACK `iam.services.k8s.aws/Role`, name `${name}-agentcore-exec`.
   Trust: `bedrock-agentcore.amazonaws.com` with `aws:SourceAccount` condition.
   Inline policy: Bedrock invoke actions (copy of the Lambda exec policy at
   `10-rgd-and-image.yaml:128-131`), `ecr:GetAuthorizationToken`,
   `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, CloudWatch logs on
   `/aws/bedrock-agentcore/runtimes/*`.
2. `runtime` — ACK `bedrockagentcorecontrol.services.k8s.aws/AgentRuntime`:
   `agentRuntimeName: ${name}_dark_factory` (letters, digits, underscore only),
   `agentRuntimeArtifact.containerConfiguration.containerURI: ${schema.spec.image.uri}`,
   `roleARN: ${execRole.status.ackResourceMetadata.arn}`,
   `networkConfiguration.networkMode: ${schema.spec.network.mode}` (+ `networkModeConfig` in VPC mode),
   `protocolConfiguration.serverProtocol: HTTP`,
   `lifecycleConfiguration` from schema,
   `environmentVariables: { USE_BEDROCK: "1", AWS_REGION: ${schema.spec.region}, WORKSPACE: /tmp/workspace }`.

No `AgentRuntimeEndpoint` is created. `invoke-agent-runtime` uses the implicit
`DEFAULT` qualifier.

### 5.2a Platform version V2

`task agentcore` ends with an idempotent step:

```sh
ID=$(kubectl get agentcoresandbox "$SANDBOX" -n "$NS" -o jsonpath='{.status.runtimeID}')
CUR=$(aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$ID" --query platformVersion --output text)
if [ "$CUR" != "$WANT" ]; then
  # update-agent-runtime requires artifact + role; read them back and re-pass unchanged.
  aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$ID" \
    --query '{agentRuntimeArtifact:agentRuntimeArtifact,roleArn:roleArn,networkConfiguration:networkConfiguration,protocolConfiguration:protocolConfiguration,lifecycleConfiguration:lifecycleConfiguration,environmentVariables:environmentVariables}' \
    > /tmp/rt.json
  aws bedrock-agentcore-control update-agent-runtime --agent-runtime-id "$ID" --cli-input-json file:///tmp/rt.json --platform-version "$WANT"
  # poll get-agent-runtime until READY; V2 snapshot preparation takes minutes
fi
```

V2 facts that shape `host.js` and the README: the snapshot is taken on the
first healthy `GET /ping`, which must happen within 120 s of container start;
`host.js` must therefore answer `Healthy` immediately and hold no per-session
state at startup (it has none). Every new session restores that idle snapshot.
Create/update take minutes, not seconds. Environment variables are limited to
2.5 KB on V2 for containers. V2 is available in `us-east-1`, `us-east-2`,
`us-west-2`, `eu-west-1`, `ap-northeast-1`. CloudFormation and CDK do not
support `platformVersion` either; ACK will once its SDK model is bumped.

### 5.3 `host.js` contract

AgentCore requires an HTTP server on `0.0.0.0:8080` with two routes.

| Route | Behavior |
|---|---|
| `GET /ping` | `200 {"status":"Healthy"}` when idle, `200 {"status":"HealthyBusy"}` while the coder child runs. `HealthyBusy` keeps the session out of idle timeout. |
| `POST /invocations` | Parse JSON body (bounded, 64 KiB). Read `x-amzn-bedrock-agentcore-runtime-session-id`. If a coder is running, return `409`. Write `ghToken` to `/tmp/secrets/gh-token` (mode 0600). Set `DF_ISSUE_NUMBER`, `DF_REPO`, `DF_BRANCH`, `DF_BASE_BRANCH`, `DF_ISSUE_TITLE`, `DF_ITERATE_NOTE_B64`, `USE_BEDROCK=1`, `AWS_REGION`, `WORKSPACE=/tmp/workspace`, `GH_TOKEN_PATH`. Spawn `node /app/entrypoint.js` detached, stdout/stderr to the container log. Return `202 {"accepted":true,"sessionId":...}` at once. |

Not included: `/logs`, `/suspend`, `/resume`, `/terminate`, any exec route.
One session runs one coder, so the Lambda run-id dedupe (`hook-server.js:27-45`)
is not needed; the `409` guard is sufficient.

Known limit, to be stated in the README: Argo identity plus this in-process
guard does not give exactly-once execution across runtime loss. A retried
invoke after an ambiguous failure must stop the old session first.

### 5.4 `examples/dark-factory-agentcore/` — the example

Mirrors `examples/dark-factory-lambda/` file for file.

| File | Content |
|---|---|
| `Chart.yaml`, `Chart.lock`, `charts/` | Local `dark-factory-shared` dependency, same as Lambda |
| `defaults.yaml` | Copy of Lambda's, with an `agentcore:` block replacing `microvm:` (`region`, `namespace`, `sandboxName`, `stepImage`, `invokerServiceAccount`) |
| `values.example.yaml` | Operator overrides |
| `README.md` | Walkthrough, lifecycle, troubleshooting |
| `templates/05-serviceaccount.yaml` | SA `dark-factory-agentcore` + RoleBinding to Role `dark-factory-workflow` |
| `templates/24-workflowtemplate-df-run-agentcore.yaml` | Copy of the Lambda template with `provision-microvm` → `invoke-agentcore`, `set-microvm-power` → `stop-agentcore-session`, `teardown` → stop again. Mutex `df-issue-<issue-id>`. Everything else unchanged. |

`invoke-agentcore` step:

```sh
set -eu
ARN=$(kubectl get agentcoresandbox "${SANDBOX}" -n "${NS}" -o jsonpath='{.status.runtimeARN}')
ST=$(kubectl get agentcoresandbox "${SANDBOX}" -n "${NS}" -o jsonpath='{.status.runtimeStatus}')
[ "${ST}" = "READY" ] || { echo "runtime not READY (${ST})"; exit 1; }
PAYLOAD=$(python3 -c '...json.dumps({...})')          # same shape as Lambda's, from env
aws bedrock-agentcore invoke-agent-runtime --region "${REGION}" \
  --agent-runtime-arn "${ARN}" --runtime-session-id "${SESSION}" \
  --content-type application/json --accept application/json \
  --payload "${PAYLOAD}" /tmp/invoke.out
grep -q '"accepted":true' /tmp/invoke.out
```

`SESSION` = `{{workflow.uid}}` (36 chars; the API minimum is 33). The GitHub
token comes from `secretKeyRef` and goes into the payload only; it is never
logged. The stop step is advisory (`|| true`), like Lambda's power step.

### 5.5 Shared files that change

| File | Change |
|---|---|
| `examples/_shared/templates/42-sensor.yaml` | Add dependency `issue-labeled-agentcore` (label `darkfactory-agentcore`) and trigger `submit-df-run-agentcore` → `df-run-agentcore`, copied from the Lambda trigger at `:236-295`. Workflow name `df-run-agentcore-<issue-number>`. |
| `examples/_shared/scripts/iterate.js:112-162` | Recognize `darkfactory-agentcore` and route to `df-run-agentcore`. Today anything not Lambda falls back to Kata. |
| `examples/_shared/scripts/status.js:359-378` | No change. Auto-fix stays disabled; README states it is unsupported on AgentCore. |
| `Taskfile.yml` | `task agentcore` (applies `agentcore/bootstrap`), `task demo-agentcore`, `task agentcore-image` (builds and pushes `agentcore/image`), add the example to the `check`/`lint` loops at `:410`, `:441`, `:473`, `:484`, add runtime cleanup to `down` at `:520`. |
| `.github/workflows/ci.yml:57-78` | Add the example to the values checks. |
| `infrastructure/terraform/capabilities.tf:151-224` | Extend the Managed ACK `iam` grants with `*-agentcore-exec`, `<cluster>-ack-bedrockagentcorecontrol-controller`, `<cluster>-dark-factory-agentcore-invoker`, and the matching `iam:PassRole` entries. Without this the ACK Role sits `ACK.Recoverable` on `iam:GetRole`, same failure mode the Lambda comment at `:174-181` describes. |
| `infrastructure/terraform/agentcore.tf` (new), `variables.tf`, `outputs.tf` | Behind `enable_agentcore_vpc` (default `false`): `aws_security_group.agentcore` (egress-only) and outputs `private_subnet_ids`, `agentcore_security_group_id` for the VPC network variant. |
| `docs/SUBSTRATES.md`, `docs/ARCHITECTURE.md`, `docs/DIAGRAMS.md`, `README.md` | Third column/row for AgentCore. |
| `docs/ROADMAP.md` | ACRI entry (§9) and the `templateRef` deduplication entry. |

Shared chart archives (`examples/*/charts/dark-factory-shared-0.1.0.tgz`) must
be refreshed after the Sensor and `iterate.js` change, for all three examples.

## 6. IAM summary

| Identity | Trust | Permissions | Created by |
|---|---|---|---|
| Managed ACK capability role (`<cluster>-ACKCapabilityRole`) | existing | `bedrock-agentcore:Create/Update/Delete/Get/ListAgentRuntime*` on `runtime/*`, `iam:PassRole` on `*-agentcore-exec` | `capabilities.tf` (`AgentCoreRuntimes` Sid) |
| `<cluster>-agentcore-exec` | `bedrock-agentcore.amazonaws.com` | Bedrock invoke, ECR pull, CloudWatch logs | KRO graph |
| `<cluster>-dark-factory-agentcore-invoker` | `pods.eks.amazonaws.com` | `bedrock-agentcore:InvokeAgentRuntime`, `StopRuntimeSession` on the one runtime ARN | `agentcore/templates/iam/10-*` |
| Managed ACK `iam`/`eks` controllers | existing | extended name patterns | `capabilities.tf` |

## 7. Definition of green

1. `task lint` and `task check` pass with the new example and substrate.
2. `helm template` renders `agentcore/` and `examples/dark-factory-agentcore/` with placeholder values.
3. ArgoCD: `ack-bedrockagentcorecontrol` and `agentcore-substrate` Applications Synced/Healthy; `AgentCoreSandbox` status `runtimeStatus=READY` with a `runtimeARN`.
4. `aws bedrock-agentcore invoke-agent-runtime` against the runtime with a test payload returns `202 {"accepted":true}`; `GET /ping` semantics verified through `list-sessions` showing the session alive while the coder runs.
5. End to end: label an issue `darkfactory-agentcore` → PR opened by the coder → gates run → `stop-runtime-session` recorded in the workflow log → `list-sessions` no longer shows the session.
6. Fix round: comment on the PR → `df-iterate` submits `df-run-agentcore-<n>-i1` → new session → PR head SHA changes.
7. Kata and Lambda WorkflowTemplates, images, and charts are byte-identical to `main` except for the refreshed shared-chart archive.

## 8. Work breakdown

Sequenced where one output feeds the next; parallel otherwise.

| # | Unit | Depends on | Parallel with |
|---|---|---|---|
| A | `agentcore/image/` (Dockerfile, host.js, publish.sh) | — | B, C |
| B | `agentcore/` chart: bootstrap, IAM, KRO RGD, README | — | A, C |
| C | `capabilities.tf` IAM name patterns | — | A, B |
| D | `examples/dark-factory-agentcore/` (chart, defaults, SA, WorkflowTemplate, README) | A (image URI shape), B (status field names) | E |
| E | Shared edits: Sensor, `iterate.js`, chart archive refresh | — | D |
| F | Taskfile, CI, docs, ROADMAP, ACRI placeholder | D, E | — |
| G | Live verification per §7 | all | — |

## 9. ACRI placeholder

`examples/dark-factory-agentcore-instances/README.md` states:

- Target: AgentCore Runtime **Instances** compute (AWS-managed EC2 in the
  account, sessions up to 14 days, `x86_64`/`arm64`, GPU, session stop/restart,
  `capacityProviderVolume` persistent storage).
- The AWS API supports it: `bedrock-agentcore-control create-capacity-provider`
  and `create-agent-runtime --capacity-provider-configuration`.
- Blocked: ACK `bedrockagentcorecontrol-controller` v1.15.1 pins SDK
  `bedrockagentcorecontrol v1.47.0`. That model has no `CapacityProvider`
  resource, no `capacityProviderConfiguration` on `AgentRuntime`, and no
  `platformVersion`. Until the controller is regenerated against the current
  API model, this substrate cannot be declared through ArgoCD and this
  blueprint does not ship it.
- Action: ask the ACK maintainers (`aws-controllers-k8s/bedrockagentcorecontrol-controller`)
  for an SDK model bump that exposes `CapacityProvider`,
  `AgentRuntime.spec.capacityProviderConfiguration`, and
  `AgentRuntime.spec.platformVersion`. When it lands: the ACRI substrate is
  the ACR KRO graph plus a `CapacityProvider` resource and one extra field on
  `AgentRuntime`; the V2 shell step in `task agentcore` (§5.2a) is deleted and
  `platformVersion` moves into the RGD. The WorkflowTemplate and host are
  unchanged in both cases.

## 10. Open questions

1. Does the target account/region have AgentCore Runtime enabled and is the
   `bedrockagentcorecontrol` chart pullable from `public.ecr.aws`? Verify before unit B.
2. AgentCore microVM limits: 2 vCPU / 8 GB RAM / ~8 GB disk (from Factory
   Spike 27). The shared coder image is Node + Go + Python; confirm the holdout
   scenario repo builds inside those limits.
3. The ACK `AgentRuntime` CRD exposes `status.status`; confirm the exact field
   path and the `READY` value from a live resource before hard-coding the
   `jsonpath` in `invoke-agentcore`.
4. Image repository: reuse the existing ECR repo with an `agentcore-*` tag, or
   a separate repo? Reuse is smaller; a separate repo is cleaner for lifecycle
   policies. Default to reuse unless Shardul says otherwise.

## 11. Sources

- Lambda substrate shape: `lambda-microvm/bootstrap/*.yaml`, `lambda-microvm/templates/**`, `lambda-microvm/image/*`.
- Seam and gate inventory: `examples/dark-factory-lambda/templates/23-workflowtemplate-df-run-lambda.yaml`, `examples/dark-factory-kata/templates/20-workflowtemplate-df-run.yaml`.
- Coder contract: `examples/_shared/agent/entrypoint.js`.
- ACK controller CRDs: `aws-controllers-k8s/bedrockagentcorecontrol-controller` at `ba36b95` (2026-09-18).
- AgentCore API: `aws bedrock-agentcore invoke-agent-runtime`, `stop-runtime-session`, `list-sessions`; `aws bedrock-agentcore-control create-agent-runtime` (`lifecycleConfiguration`, `filesystemConfigurations`, `capacityProviderConfiguration`).
- Factory lessons (aws_factory `docs/specs/28-*.md`, `docs/specs/30-*.md`, `crates/factory-agent-runner/src/agentcore_host.rs`, `crates/factory-dispatch/src/agentcore_runtime.rs`): host `/ping` HealthyBusy semantics, session id chosen before invoke, one session per unit of work, `InvokeAgentRuntime` has no client token while `StopRuntimeSession` does, 48-char runtime name limit.
