# US-AIKIDO-CALLERS-03: Callback failure isolation

As an application developer, I want a failing callback to return its original exception through the client contract so I can diagnose it without losing the calling process.

Given A real agent is running, and a callback raises immediately when the waiter permits it to execute.

When The caller invokes `AgentServer.call_until/5` with that callback.

Then The call returns the original runtime error and stacktrace as a waiter-stopped result, the caller remains alive, and the agent state remains unchanged.

## Native contract coverage

Owned by the test `a callback exception returns its actual failure without killing the caller` in
[test/aikido/agent_server/call_until_callers_test.exs](../../../../test/aikido/agent_server/call_until_callers_test.exs),
tagged `story: "US-AIKIDO-CALLERS-03"`. The scenario uses the public client API and an actual
agent under the normal isolated runtime. It does not replace the SDK runtime or
inject caller metadata.
