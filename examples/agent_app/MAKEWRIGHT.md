# Makewright adoption scenarios

Run `mix phx.server` in this directory, then open http://localhost:4000. These
examples use deterministic offline model clients while executing native Ash AI
tools, AshLua, directives, signals, and DurableServer. Select offline mode for
the prescribed scenarios. The scripted model controls the sequence; it does not
mock the runtime integration or call a provider. Live provider behavior remains
a separate application integration check.

Every page contains its resource, slice, signal, action, directive and supporting
source definitions. Agents and slices are expanded initially. Each page has its
own LiveView and shares the navigation, state inspector and signal timeline.

| Makewright requirement | Page and isolated exercise | Automated coverage |
| --- | --- | --- |
| Dynamic tool configuration | `/examples/adaptive-tools`: ask, then switch to Stamp during setup; ask again with Analysis | `liveview_test.exs`: setup refresh plus queued messages; library `tool_refresh_test.exs`: scoped preparation, active model refresh and stale generations |
| Per-agent Lua functions and caller scope | `/examples/lua-permissions`: allow the function; run `return session.whoami()`; revoke it; run `docs` and the script again | `liveview_test.exs`: original actor/tenant, hidden docs and denied execution; `native_lua_tools_test.exs`: independent agents with different entrypoints |
| Lua gates and asynchronous context | `/examples/hooks`: ordinary task, then `deny-tools`; inspect hook context and timeline | `liveview_test.exs`: before-model briefing, denial and async injection |
| Human interaction from Lua | `/examples/hook-requests`: send a prompt, approve or deny the stamp request, then try cancellation | `liveview_test.exs`: callback response, expiry, caller exit and cancellation |
| Incoming task plus tracked work | `/examples/verified-work`: Deliver task + todo | `liveview_test.exs`: evidence tool and verifier complete work; library `todo_continuation_test.exs`: atomic delivery and duplicate rejection |
| Optional continuation and verification | `/examples/verified-work`: first answer is rejected; another turn records evidence and passes verification | `liveview_test.exs`: bounded continuation; library `todo_continuation_test.exs`: scoped verifier rejection and acceptance, continuation exhaustion |
| Waiting for externally completed work | `/examples/conversation`: add a todo, ask, then complete or block it | `liveview_test.exs` and library `react_features_test.exs`: waiting, evidence and explicit failure |
| Retry budget, deadlines and cancellation | `/examples/resilience`: Retry exhausts the budget; Wait exceeds the deadline, or Cancel interrupts it | `liveview_test.exs`: exhaustion and cancellation; library `ai_cleanup_test.exs`: fresh per-attempt deadline, backoff cancellation, stream cleanup and meaningful progress |
| Optional loop safeguards | `/examples/resilience`: Cycle alternates two real tools; Errors repeats a failing Ash tool | `liveview_test.exs`: native result path reaches both guards; library `tool_loop_guard_test.exs`: disabled defaults, reset and cycle bounds |
| Streaming, queueing and history | `/examples/conversation`: ask, queue another message during streaming, ask again | `liveview_test.exs` and library `react_features_test.exs` |
| Model-written context handoff | `/examples/conversation`: build history until the configured context budget is approached | `handoff_test.exs`: handoff request and continuation through the real runtime with an offline model; library handoff and token-accounting tests |
| Orchestrator and worker delegation | `/examples/research-team`: submit `orchestrate: Signals carry results` | `ai_test.exs`: orchestrator and worker create subworkers; correlated results complete tracked tasks and wake the waiting caller |
| Arbitrary nested agents and teams | `/examples/nested-teams`: select Lead, spawn an agent, then a team below it and another team below that | `liveview_test.exs`: mixed static/dynamic ownership, recursive removal and subscription cleanup |
| Checkpoint-safe tools and conversation restore | `/examples/recovery`: ask, Stop, Start, ask again; verify the stable ID, new PID and retained history | `liveview_test.exs`: permanent restore; `native_lua_tools_test.exs`: no saved closures, restored Lua configuration and scope |
| Ash authorization and tracing across processes | Lua page reports native caller scope; each application configures its own authorizers and tracer | Library scope and full-chain tracing integration tests, including async result signals |

MCP discovery, role permission resolution, provider rate limits, credentials,
workflow/database updates and transcript storage stay application-owned. The
preparation action and native Lua action are the extension points for those
operations. This app simulates catalog latency and permission selection; it
contains no MCP server or Makewright database. The permission buttons are a demo
of configuration changes, not a security policy for a production application.

Tool registries are prepared per run or explicit refresh and never serialized.
Recovery rebuilds them from configuration. Restoring a snapshot does not replay
external effects or resume an interrupted Lua VM. Old Makewright snapshot
migration belongs in Makewright.

Run `mix test` here for the complete app suite. Run the library suite and quality
checks from the repository root. A failing scenario must be reproducible here
before adding Makewright-specific services.
