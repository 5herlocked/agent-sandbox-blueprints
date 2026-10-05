# Dark Factory on AgentCore Runtime Instances (ACRI) — placeholder

This variant targets **AgentCore Runtime Instances** compute: AWS-managed EC2 in
your account, sessions up to 14 days, `x86_64` or `arm64`, GPU, session
stop/restart, and `capacityProviderVolume` persistent storage. No chart or
deployable example is shipped here yet.

The AWS CLI supports `bedrock-agentcore-control create-capacity-provider` and
`create-agent-runtime --capacity-provider-configuration`. But ACK
`bedrockagentcorecontrol-controller` v1.15.1 pins SDK
`bedrockagentcorecontrol v1.47.0`. Its model has no `CapacityProvider`, no
`AgentRuntime.spec.capacityProviderConfiguration`, and no `platformVersion`.
Without these CRD fields, ArgoCD cannot declare this substrate through the same
KRO/ACK path as [AgentCore Runtime](../dark-factory-agentcore/README.md).

**Maintainer ask:** bump the SDK model in
`aws-controllers-k8s/bedrockagentcorecontrol-controller` to expose
`CapacityProvider`, `AgentRuntime.spec.capacityProviderConfiguration`, and
`AgentRuntime.spec.platformVersion`. Once available, add a `CapacityProvider`
and one extra field to the AgentCore KRO graph. Move V2 into the graph and
remove the imperative `task agentcore-v2` step. The WorkflowTemplate and HTTP
host do not need to change. See [the plan](../../docs/AGENTCORE-PLAN.md#9-acri-placeholder).
