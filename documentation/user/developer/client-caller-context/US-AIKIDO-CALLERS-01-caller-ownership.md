# US-AIKIDO-CALLERS-01: Caller ownership

As an application developer, I want callback dispatch to retain native caller ancestry so an existing caller-based Ash policy still applies when I await agent completion.

Given A real agent is running under an isolated Aikido runtime, and its generated inspect command uses an Ash policy that requires the request owner in the native caller chain.

When The owner calls `AgentServer.call_until/5` with a callback that performs that authorized inspect and dispatches the generated write command.

Then The isolated waiter retains the real owner in its native Task ancestry, the policy permits the read, and the routed write completes with the expected value.

## Native contract coverage

Owned by the test `a callback retains caller ownership while dispatching real Ash commands` in
[test/aikido/agent_server/call_until_callers_test.exs](../../../../test/aikido/agent_server/call_until_callers_test.exs),
tagged `story: "US-AIKIDO-CALLERS-01"`. The scenario uses the public client API and an actual
agent under the normal isolated runtime. It does not replace the SDK runtime or
inject caller metadata.
