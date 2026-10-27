# AGENTS.md - Aikido Test Support Guide

## Intent
Provide stable, reusable testing patterns for pure agents, AgentServer runtime behavior, and multi-agent flows.

## Runtime Baseline
- Elixir `~> 1.19`
- OTP `28+` (release QA baseline)

## Commands
- `mix test`
- `mix test test/path/to/file_test.exs`
- `mix test --cover`
- `cd examples/agent_app && mix test`

## Support Modules
- `AikidoTest.Case`: isolated Aikido instance per test (`aikido`, `aikido_pid` context)
- `AikidoTest.AgentWait`: subscription-based state assertions
- `AikidoTest.LifecycleWait`: process monitors and supervised recovery events
- `AikidoTest.Support.TestTracer`: lightweight span capture for runtime assertions
- Fixtures in `test_agents.ex` and `AikidoTest.TestActions`: native resources and action implementations for behavior-level tests

## Standards
- Prefer behavior assertions over implementation/log assertions
- Integration fixtures should be real agents or mounted slices with their own
  schemas, typed signals and routes. Send signals through the agent pipeline;
  do not introduce standalone resources solely to wrap unrelated reducer actions.
  Keep focused unit tests of native Ash actions, explicit action references and
  pure routing contracts when those contracts are the behavior under test.
- Standalone native resources belong in external-tool, embedded-data and native
  integration contracts. Do not use them as generic reducer harnesses. Shared
  fixture domains must use normal application registration and resource inclusion.
- Build resource scenarios through native create actions with their scenario
  attributes supplied as inputs. Do not use `apply_attributes`, bare resource
  struct constructors or map overlays to bypass casting, defaults and changes.
  Construct malformed resources explicitly only in tests of input rejection.
- Avoid `Process.sleep/1`; use subscriptions and monitored process lifecycle checks
- Keep tests focused and deterministic (single behavior per test where practical)
- Test application-facing lifecycle through domain actions. Runtime-specific tests activate fixtures directly through `Aikido.Durable`; agents stay owned by the shared DurableServer supervisor. Observe termination with monitors rather than caller links.
- Use unique IDs/helpers to avoid test cross-talk

## High-Value Coverage
- Native Ash action immutability and directive emission semantics
- AgentServer signal routing and runtime directive execution
- DurableServer activation, snapshot retention, codec round trips and recovery
- Parent-child lifecycle (`SpawnAgent`, `StopChild`) and state synchronization
- Action result shapes — each reducer returns state only for its own resolved mount path;
  test coordinated updates through separately routed actions and rollback on failure

## Release Hygiene
- Keep test fixtures aligned with current directive/slice-return/tool contracts
- Use Conventional Commits
- Update examples in `examples/agent_app/` when behavior contracts change

## References
- `test/support/`
- `examples/agent_app/test/`
- `../README.md`
- https://github.com/barnabasJ/aikido
