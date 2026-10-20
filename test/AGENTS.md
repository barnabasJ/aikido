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
- Avoid `Process.sleep/1`; use subscriptions and monitored process lifecycle checks
- Keep tests focused and deterministic (single behavior per test where practical)
- Test application-facing lifecycle through domain actions. Runtime-specific tests use the internal `Aikido.start_agent/3` path; agents stay owned by the shared DurableServer supervisor. Observe termination with monitors rather than caller links.
- Use unique IDs/helpers to avoid test cross-talk

## High-Value Coverage
- Native Ash action immutability and directive emission semantics
- AgentServer signal routing and runtime directive execution
- DurableServer activation, snapshot retention, codec round trips and recovery
- Parent-child lifecycle (`SpawnAgent`, `StopChild`) and state synchronization
- Action result shapes — state for the resolved mount path, multiple slices via `%Aikido.Agent.SliceUpdate{}`

## Release Hygiene
- Keep test fixtures aligned with current directive/slice-return/tool contracts
- Use Conventional Commits
- Update examples in `examples/agent_app/` when behavior contracts change

## References
- `test/support/`
- `examples/agent_app/test/`
- `../README.md`
- https://github.com/barnabasJ/aikido
