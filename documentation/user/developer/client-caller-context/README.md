# Native client caller context

These developer stories cover callback dispatch through
`Aikido.AgentServer.call_until/5`: native caller ancestry, nested Task ownership,
and exception isolation. Each story owns one
behavior test; the supporting resource is a real routed agent.

| Story                                                            | Contract                   | Owning test                                                                   |
| ---------------------------------------------------------------- | -------------------------- | ----------------------------------------------------------------------------- |
| [US-AIKIDO-CALLERS-01](US-AIKIDO-CALLERS-01-caller-ownership.md) | Caller ownership           | `a callback retains caller ownership while dispatching real Ash commands`     |
| [US-AIKIDO-CALLERS-02](US-AIKIDO-CALLERS-02-nested-task.md)      | Nested Task ancestry       | `a callback retains the whole native chain when its caller is already a Task` |
| [US-AIKIDO-CALLERS-03](US-AIKIDO-CALLERS-03-callback-failure.md) | Callback failure isolation | `a callback exception returns its actual failure without killing the caller`  |

The tests live in
[test/aikido/agent_server/call_until_callers_test.exs](../../../../test/aikido/agent_server/call_until_callers_test.exs).
Story tags and these pages add traceability; they do not change runtime behavior
or replace the SDK and application integration verification receipts.
