# Dark Factory on Amazon Bedrock AgentCore Runtime

The same pipeline as the Kata and Lambda examples, with the coder running in a
**disposable AgentCore Runtime session for each round**. GitHub holds the branch,
issue, and review feedback between rounds. The runtime uses direct Bedrock
inference through its execution role.

**Prerequisites:** `task up`, a platform runtime deployed with `task agentcore`,
and a throwaway GitHub repo. Run the task commands below from the repository root.

## 1. Configure

```bash
cp examples/dark-factory-agentcore/values.example.yaml examples/dark-factory-agentcore/values.yaml
```

Edit `trigger.argoEvents.repositories`, `trigger.argoEvents.webhookUrl`, and
`agentcore.region`. `task demo-agentcore` injects `agentcore.sandboxName` from the
Taskfile var `AGENTCORE_SANDBOX` (default `coder`); it must match the platform's
`AgentCoreSandbox` instance created by the `agentcore/` chart.

The chart contains a shared subchart. Repeat overrides for shared settings, such
as `trigger`, `github`, `iterate`, and review gates, under `dark-factory-shared:`
as well as at the top level. Task-provided image and cluster settings are injected
at both scopes. The defaults disable the shared chart's Lambda Pod Identity
association for this example.

Keep account-specific configuration and credentials out of git.

## 2. Create the GitHub Secret and webhook

Follow [`../_shared/SECRETS.md`](../_shared/SECRETS.md). The workflow reads the
GitHub token from the configured Secret in the Argo namespace. The shared Sensor
routes the fixed label `darkfactory-agentcore` to `df-run-agentcore`.

## 3. Build the runtime image

Follow [`../../agentcore/README.md`](../../agentcore/README.md) to build and
publish the ARM64 runtime image with `task agentcore-image`, then deploy the
platform runtime with `task agentcore`. The runtime image wraps the shared coder
with an HTTP host. The example chart consumes its ARN from sandbox status.

## 4. Deploy the pipeline

```bash
task demo-agentcore
```

The workflow uses `dark-factory-workflow` for its common steps. Only
`invoke-agentcore` and `stop-agentcore-session` use `dark-factory-agentcore`.
EKS Pod Identity permits one association per ServiceAccount, so the dedicated
account receives the runtime invoker role. Its RoleBindings allow Argo result
publication and reading the one configured sandbox.

## 5. Run it

Label an issue `darkfactory-agentcore`. Choose one small, testable change.
The Sensor submits `df-run-agentcore-<issue-number>` using the
`df-run-agentcore` WorkflowTemplate.

## What you should see

| Stage | What happens |
|---|---|
| Invoke | Wait for the sandbox's `status.runtimeStatus` to be `READY` and `status.runtimeARN` to be non-empty, then invoke a new session |
| Code | The host starts the shared coder, which implements, tests, pushes `df/issue-N`, and opens the PR |
| Await | `await-coder` polls GitHub for the PR and its implementation status |
| Stop | `stop-agentcore-session` ends the session after the coder completes; review gates run in hub pods |
| Gates | The copied holdout, DevOps, security, deploy-test, and status steps report on the PR |
| Exit | `teardown` calls the same advisory stop again, including after failure |
| Fix round | A human comment routes through `df-iterate` to a new `df-run-agentcore` workflow and session |
| Merge | Human approval follows the shared merge path; the session has already stopped |

`invoke-agentcore` downloads a static kubectl because the AWS CLI step image does
not contain it. It waits up to about ten minutes for the runtime, builds JSON from
environment variables, and calls `aws bedrock-agentcore invoke-agent-runtime`.
The payload contains `ghToken`, `region`, `issueNumber`, `repo`, `branch`,
`baseBranch`, `issueTitle`, `iterateNoteB64`, and `iterateNote`. The token comes
from `secretKeyRef`; the payload is never logged.

The session ID is `{{workflow.uid}}`, a 36-character UUID that meets the API's
33-character minimum. The CLI writes the response body to `/tmp/invoke.out`.
The step requires `accepted: true`, logs only the first 120 characters of that
response, and exports `session-id`.

The host returns **HTTP 202** with `{"accepted":true,"sessionId":"..."}` after
starting the coder. This means accepted, not completed; GitHub reports completion.
An invoke while the same session's coder is running returns **409**. The workflow
reports that failure and runs its exit stop. Stop failures remain advisory, and
a second stop of an ended session does not fail the workflow.

Argo identity plus this in-process guard does not give exactly-once execution
across runtime loss. A retried invoke after an ambiguous failure must stop the
old session first.

## Verification

```bash
kubectl get wf -n argo
kubectl get agentcoresandbox <sandbox-name> -n agent-sandbox-system -o yaml

ARN=$(kubectl get agentcoresandbox <sandbox-name> -n agent-sandbox-system \
  -o jsonpath='{.status.runtimeARN}')
SESSION=$(kubectl get wf <workflow-name> -n argo -o jsonpath='{.metadata.uid}')
echo "$SESSION"
aws bedrock-agentcore list-sessions --region us-west-2 \
  --agent-runtime-arn "$ARN" --output json
```

Match the workflow UID to the session. Check that the session is active while the
coder works and no longer active after the stop. Review the workflow logs for the
invoke acceptance and stop result. Runtime creation or update, including V2
snapshot preparation, can take minutes.

## Requesting a fix

Comment on the PR with the requested change. `df-iterate` reads the originating
issue's label and submits `df-run-agentcore-<issue-number>-i<round>`. Keep the
`darkfactory-agentcore` label on that issue.

Each round uses a fresh workspace. In the shared coder's `checkout()`, a revision
note makes the coder clone the existing `df/issue-N` branch; a first pass clones
the base branch and creates `df/issue-N`. If the revision branch is missing, it
falls back to the base branch. GitHub therefore holds the state needed to continue
work. There is no session storage or suspend/resume path.

**Auto-fix (`status.js`) is unsupported on this substrate.** Keep
`review.autoFixFindings: false`; `status.js` still submits the Kata template.
Use the human-driven `df-iterate` path. The shared Sensor also has a known
PR-comment filter issue; if comments do not trigger a workflow, use the direct
`df-iterate` submission workaround in [`../../docs/ROADMAP.md`](../../docs/ROADMAP.md).

## Troubleshooting

| Symptom | Cause or check | Action |
|---|---|---|
| Invoke times out waiting for `READY` | Runtime creation/update is pending, or the sandbox name/namespace is wrong | Check `AgentCoreSandbox` status and the ACK `AgentRuntime` conditions; match `agentcore.sandboxName` to the platform instance |
| Sandbox read returns `Forbidden` | The invoker SA lacks its sandbox RoleBinding, or the configured namespace/name differs | Check the example's `dark-factory-agentcore-sandbox` Role and binding against the step's SA and sandbox |
| Retry returns 409 | A coder is still running in that session | Check GitHub and workflow logs, then stop the old session before a retry after an ambiguous failure |
| Session remains active beyond its idle timeout | The host reports `HealthyBusy` while the coder child runs | This is expected. Idle timeout applies when the host reports `Healthy`; the maximum lifetime remains the backstop |
| Session ends while the coder should be busy | Check host health, process exit, and maximum lifetime | Inspect runtime logs; verify `/ping` reports `HealthyBusy` for a live coder and check the platform lifecycle limits |
| Stop logs an advisory error | The session may already be ended, or the call failed | Read the underlying CLI error and verify the session with `list-sessions` |

## Cleanup check

Confirm there is no active session for the workflow UID. If a session remains,
stop it with the ARN and UID from the verification commands:

```bash
aws bedrock-agentcore stop-runtime-session --region us-west-2 \
  --agent-runtime-arn "$ARN" --runtime-session-id "$SESSION"
aws bedrock-agentcore list-sessions --region us-west-2 \
  --agent-runtime-arn "$ARN" --output json
```

The platform-owned runtime remains available for the next round. Use `task down`
when the whole blueprint deployment is finished.
