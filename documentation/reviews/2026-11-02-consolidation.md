# Aikido consolidation review

The integration source starts at `3d468c332fb524228c6d5291fe64b08d59f62934`, the published union of the runtime diagnostics, subscription budget, and terminal deadline fixes. Earlier notification/state adoption, scoped recovery, summary regeneration, and loop comparison branches are ancestors of this union, not independent implementations to copy again.

The original working copy is preserved separately during integration. Its source was compared against the native-runtime snapshot (`448cd6b8`) and the union. Local changes to AI internals that would reverse later native state changes, result correlation, failure-at-cap semantics, compiler-safe client initialization, or loop comparison were superseded by the newer implementation. Local inspector capture controls, native sensitivity metadata, efficient size accounting, heartbeat isolation, batched progress, metrics graphs, benchmark sources/evidence, domain registration fixes, and their tests were merged separately. The staged preflight candidate was included; test-only subscription tuple matches were adapted to the combined capture flag protocol.

## Ownership decisions

| Feature | SDK responsibility | Application responsibility |
| --- | --- | --- |
| State changes and notifications | Native Ash update validates sparse changes; explicit calculations compose publication data; native PubSub delivers | Topic authorization, receiving actor/tenant, resource read policies and application projections |
| Durable authority | Optional scope adapter restores native scope after the actual durable claim; SDK validates its own claimed identity | Credential issuance/revocation, account/grant checks, business identity and scope derivation |
| Tool loops | Bounded fingerprints, optional pure comparison MFA, independent failed-batch streak, typed warning metadata | Semantic normalization, tool-specific equivalence, workflow response to warnings |
| Completion verification | Explicit verifier hook, typed feedback/data, bounded continuation policy | Meaning of done, evidence requirements, task-specific verification and limits |
| Runtime failures | Typed unavailable/topology/task failures; correlated bounded tool diagnostics without private payloads | Business error guidance, provider-specific rendering and recovery policy |
| Delegation deadlines | Native task timeout/cancellation and terminal delivery correlation; finished child outer deadline does not renew an active parent | Which tasks to launch, application budgets and recipient/business correlation |
| Attempt preflight | Registration and owner-state read share remaining preflight budget | Mailbox workload, observer setup order and host reaper/liveness policy |

No Makewright grants, account models, ExecutionCredential implementation, custom receiver middleware, repository scanning, workflow prompts, reaper policy, database fixtures or deployment adapters are introduced into Aikido. No broad descendant cancellation or DurableServer fork is included. Experimental Jido adapter branches and unrelated dependency-bot upgrades are excluded.

## Native Ash review

Reducer payloads/options use Ash types and constraints. State adoption uses a real private native update action; manual create/update callbacks are the resource's data-layer boundary, not reducers bypassing an action. Metadata uses native typed-struct constructors and embedded dumps. No custom scalar parser or replacement authorization system was added.

Fresh durable input is a distinct pre-claim serialization boundary. The recursive `BootstrapShape` and `BootstrapCallbacks` modules are removed. Flat constrained Ash maps select mounted paths and immediate declared attributes. Each paired owner codec, or the application scope adapter's explicit preparation callback, owns safe persisted content. Native term dump/load checks portable serialization without writing a fallback. Field casting, constraints, defaults and embedded creation remain in native initialization after the durable claim. Nested opaque content is not promised to undergo a recursive pre-storage sanitization pass.

Hooks store Lua scripts and serializable settings only. The rejected per-hook Elixir request callback, its native function field, special VM injection and callback serialization tests are removed. The playground exposes approval through a normal application-owned Ash action selected by the existing AshLua surface; actor scope chooses the browser owner. Tests exercise that same native action path for waiting, cancellation and durable reactivation. The optional externalize/2 addition used only for callback serialization is removed as well. Native embedded dump/load handles initialized resources; no generic callback walker remains.

Generated public startup retains the existing native argument and slice configuration path. The callback-driven canonical AI relocation, root configuration removal and initialization mirroring are removed. Lua hook defaults, explicit overrides and durable restart are tested without an application scope-adapter workaround. Flat native key normalization and first-write checkpoint preparation checks remain independent persistence protections.

## Static analysis qualification

The three Argus finding exclusions introduced by `af696015` were removed. Unfiltered Argus reports three warnings and fails its zero-findings gate:

- Blocking: aggregates fifteen caller modules of a PID-addressed AgentServer API. This alone does not establish a globally shared PID or observed contention. Signal handling intentionally serializes a selected agent's state.
- Shutdown: analyzes AgentServer's delegated terminate callback without attributing the DurableServer host's trap-exit behavior. A runtime-supervisor shutdown integration test verifies the callback actually executes. Hard kill and shutdown timeout remain outside graceful cleanup guarantees.
- Unsafe input: dynamic interface atoms derive from compile-time Spark agent/action names. The transformer is not a request parser. Runtime/untrusted DSL compilation would require its own boundary.

No analyzer was disabled and no source was reshaped merely to hide these findings. A filtered zero-finding result is not reported as unfiltered success. These findings remain visible review qualifications.

## Verification

Original command receipts and logs are retained under the existing process guardian; failed attempts are retained too. Test counts, coverage and remaining quality results must be taken from those logs, not inferred from an ancestor branch's results.


Callback-free validation:

- Full SDK: 1,230 tests passed with warnings as errors, 86.5% coverage (original receipt `3e1775c7-c827-48c1-9c70-f716dfb4c904`). The subsequent SDK-only delta makes an unused exported helper private and corrects a test label; final compile and static checks cover it.
- Full playground: 174 tests passed with warnings as errors (original receipt `3e38f55a-6e59-40f2-8d9e-49f9d1309923`), including native approval authorization, browser response/cancellation cleanup, distinct VM capabilities and globals.
- Final SDK compile, format, Credo and Dialyzer passed (`371d3aa5-3da5-4306-95af-0afcd57549dc`); Dialyzer reported zero errors, skips or unnecessary skips.
- The finite callback-free source review binds nineteen paths, including the native approval policy. Earlier callback-portability/canonical-startup approvals are superseded.

Documentation passed with warnings as errors (`869c127c-9ffa-4a56-b477-8ea75770d93e`). Final unfiltered Argus reported the same three unsuppressed warnings and exited 1 at the zero-findings gate (`134b3318-52dc-4518-aabd-8fe0515ed636`); the qualifications above remain visible. The overall quality alias is therefore not claimed green. Original guardian receipts verify normal command exits and retired process groups for the successful runs above; failed intermediate attempts remain retained.
