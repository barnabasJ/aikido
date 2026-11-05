# US-AIKIDO-CALLERS-02: Nested Task ancestry

As an application developer, I want awaiting a command from an existing Task to preserve the full caller chain so nested asynchronous dispatch retains the original request owner.

Given An ordinary caller-owned Task dispatches against a real agent whose generated inspect policy requires the original owner.

When That Task calls `AgentServer.call_until/5`, and the callback authorizes an inspect before issuing a generated write.

Then The waiter inherits the direct Task caller and the original owner in order, the policy succeeds, and the real routed write completes.

## Native contract coverage

Owned by the test `a callback retains the whole native chain when its caller is already a Task` in
[test/aikido/agent_server/call_until_callers_test.exs](../../../../test/aikido/agent_server/call_until_callers_test.exs),
tagged `story: "US-AIKIDO-CALLERS-02"`. The scenario uses the public client API and an actual
agent under the normal isolated runtime. It does not replace the SDK runtime or
inject caller metadata.
