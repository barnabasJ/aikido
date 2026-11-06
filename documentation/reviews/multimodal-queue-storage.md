# Multimodal queue storage review

Status: the bounded compatibility adapter and both queue type declarations are
implemented in the isolated candidate for independent review. Scoped
verification results are recorded in `tmp/multimodal-verification/RESULT.md`.
Full-suite and quality checks have not run for this candidate.

## Existing load order

At base `4ff6cbd4d274ffa3b03513caec8cb1c799598ae0`:

1. DurableServer calls `Aikido.Durable.AgentServer.load_state/2` with its saved
   version and decoded envelope. This callback immediately calls
   `Aikido.Durable.Snapshot.load/1` (`durable/agent_server.ex:63`).
2. `Snapshot.load/1` decodes the transport and calls `load_agent/4`. For an
   `ash-embedded-v2` typed agent, `load_agent/4` derives the current resource
   constraints and invokes native `Ash.Type.cast_from_embedded(:struct, ...)`
   (`durable/snapshot.ex:165`). The agent and its mounted slice attributes are
   already cast here.
3. `AgentServer.init/2` then restores application scope and calls
   `initialize_authenticated/5`. Its `activation_state/2` restores the agent
   (`durable/agent_server.ex:165`).
4. Only now does `restore_agent/3` call an application `restore/2`, where
   configured, and `Codec.transform_agent(..., :reinstate)`
   (`durable/agent_server.ex:330`). Slice `reinstate/1` and `reinstate/2` are
   downstream of the typed embedded cast.

There is no declared resource or slice version-migration callback ahead of
step 2. The existing DurableServer version callback is global to the SDK host;
it is not a feature-owned pre-cast slice hook. Adding such a hook or modifying
the general snapshot envelope would expand this feature's runtime contract.
Agent-wide checkpoint callbacks can own opaque data, but cannot retroactively
intercept the existing typed-agent load path before the native cast.

## Concrete retained format

`Agent.state_from_resource/1` retains mounted slice structs. `Codec` forwards
the slice value to `externalize/1`; `AiReact.Slice.externalize/1` uses
`Map.merge`, preserving that struct. `Snapshot.storage_type/2` therefore uses
the declared embedded resource type for that path. Both `queued_messages` and
`opening_messages` were arrays of strings, dumped as native embedded
strings. Opening input is normally cleared by externalization, but retained
queued text can be nonempty.

Changing either element type directly to `:term` is incompatible with those
typed saved elements: Ash's default embedded loader delegates to `cast_stored`,
and `Ash.Type.Term.cast_stored/2` decodes an Erlang external term binary.
An old raw string is not that binary. Native union storage also requires tagged
maps, so it does not supply a transparent legacy-string load path.

Opaque application checkpoint values follow their existing restoration path;
they are not a reason to discard typed-snapshot compatibility.

## Bounded compatibility adapter

The implementation is in `lib/aikido/ai_react/types/user_content.ex`:

```elixir
defmodule Aikido.AiReact.Types.UserContent do
  use Ash.Type.NewType, subtype_of: :term

  def cast_from_embedded(<<131, _::binary>> = value, constraints),
    do: super(value, constraints)

  def cast_from_embedded(value, _constraints) when is_binary(value),
    do: Ash.Type.cast_from_embedded(:string, value)

  def cast_from_embedded(value, constraints),
    do: super(value, constraints)
end
```

The two attributes now use `{:array, UserContent}`. Runtime values remain
plain strings for text-only input and ordered lists of native ReqLLM parts for
multipart input. Native Ash Term owns every new dump and term load; native Ash
String owns the old text load. The adapter neither parses content nor walks
nested state, and does not add a second queue.

The prefix is the external-term format version byte. It cannot begin valid
UTF-8 text. This distinguishes the concrete retained UTF-8 queue format from
new term storage. It is not a universal discriminator for every arbitrary
binary that an application might previously have supplied under a string
contract. That limitation must remain explicit; broad rescue-and-treat-as-text
fallback would conceal damaged term storage and is not proposed.

Legacy non-UTF-8 values beginning with byte 131 are not accepted through the
text branch. They reach the native term decoder, which rejects invalid terms.
If an arbitrary old binary was itself a valid external term, there is no way
to infer its original text intent from these bytes. That case is outside the
retained UTF-8 compatibility contract.

Before adoption, independent review must accept this narrow storage-format
dispatch as a compatibility adapter. It is extra code above native Ash and is
not described as automatic Ash compatibility.

## Verification and removal conditions

Verification must include retained nonempty native string-array input loaded
under the candidate queue type, new mixed input through native Ash dump/load,
and an actual public agent stop/start using the durable backend. Corrupt new
term payloads and the unsupported byte-131 legacy text example must fail
rather than become text. The integration scenarios are
in `test/aikido/ai_react/multimodal_user_turn_test.exs`.

The legacy string branch can be deleted only after all supported retained
snapshots, including backups eligible for restore, have been rewritten by the
new serializer or an explicit release policy drops support for their format.
A successful current-version test run alone does not justify deletion.
