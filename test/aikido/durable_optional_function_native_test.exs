defmodule AikidoTest.OptionalFunctionNative.Callbacks do
  @moduledoc false

  def add(left, right), do: left + right
end

defmodule AikidoTest.OptionalFunctionNative.Hook do
  @moduledoc false

  use Ash.Type.NewType, subtype_of: Aikido.AiReact.Hooks.Hook
end

defmodule AikidoTest.OptionalFunctionNative.Slice do
  @moduledoc false

  use Aikido.Slice

  slice do
    name "optional_function_native"

    schema do
      attribute :hooks, {:array, Aikido.AiReact.Hooks.Hook} do
        description "Actual embedded hooks including optional callback presence."
        default []
      end

      attribute :wrapped_hooks, {:array, AikidoTest.OptionalFunctionNative.Hook} do
        description "Embedded hooks reached through declared native NewType metadata."
        default []
      end

      attribute :map_callback, :map do
        description "A constrained map is not an embedded resource attribute owner."
        constraints fields: [callback: [type: :function, constraints: [mfa: true, arity: 2]]]
        default %{}
      end

      attribute :codec_alias?, :boolean do
        description "Exercise a paired codec adding a shadow field representation."
        default false
      end

      attribute :optional, :function do
        description "Optional native callback with the literal nil default."
        constraints mfa: true, arity: 2
      end

      attribute :required, :function do
        description "Required callback whose explicit nil remains invalid."
        allow_nil? false
        constraints mfa: true, arity: 2
        default &AikidoTest.OptionalFunctionNative.Callbacks.add/2
      end

      attribute :defaulted, :function do
        description "Optional callback whose nonnil default must not replace explicit nil."
        constraints mfa: true, arity: 2
        default &AikidoTest.OptionalFunctionNative.Callbacks.add/2
      end
    end
  end

  def externalize(value), do: value

  def reinstate(value) do
    # The paired codec requires original explicit presence, including nil.
    for field <- [:hooks, :wrapped_hooks], hook <- Map.get(value, field, []) do
      true = Map.has_key?(hook, :request)
    end

    if Map.get(value, :codec_alias?),
      do: Map.put(value, "optional", &AikidoTest.OptionalFunctionNative.Callbacks.add/2),
      else: value
  end
end

defmodule AikidoTest.OptionalFunctionNative.Agent do
  @moduledoc false

  use Aikido.Agent

  agent do
    name "optional_function_native_agent"
    instance AikidoTest.Atl47Native.Instance
    slice :callbacks, AikidoTest.OptionalFunctionNative.Slice
  end
end

defmodule Aikido.DurableOptionalFunctionNativeTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias AikidoTest.OptionalFunctionNative, as: Fixture

  setup do
    instance = AikidoTest.Atl47Native.Instance
    pool = AikidoTest.OptionalFunctionNative.Pool

    directory =
      Path.join(
        System.tmp_dir!(),
        "optional-function-native-#{System.unique_integer([:positive])}"
      )

    start_supervised!(
      {Aikido, name: instance, durable: [data_dir: Path.join(directory, "runtime")]}
    )

    start_supervised!(
      {Aikido.Durable,
       name: pool,
       agent: Fixture.Agent,
       aikido: instance,
       data_dir: Path.join(directory, "anonymous"),
       durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]}
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{pool: pool}
  end

  test "public activation preserves mixed callback and nil hooks until the paired codec and initializes natively",
       ctx do
    callback = &Fixture.Callbacks.add/2
    owner = start(ctx, %{hooks: [hook("with", callback), hook("without", nil)], optional: nil})
    state = callbacks(owner)
    assert [with_callback, without_callback] = state.hooks
    assert with_callback.request.(2, 3) == 5
    assert without_callback.request == nil
    assert state.optional == nil
    assert state.defaulted.(4, 5) == 9

    assert :ok = Aikido.Durable.stop(ctx.pool, owner.pid)
    assert {:ok, restored_pid} = Aikido.Durable.start(ctx.pool, owner.id)
    assert :ok = Aikido.AgentServer.await_ready(restored_pid)
    restored = %{id: owner.id, pid: restored_pid}
    restored_state = callbacks(restored)
    assert [first, second] = restored_state.hooks
    assert first.request.(5, 6) == 11
    assert second.request == nil
  end

  test "public activation accepts all-nil embedded hooks without changing paired codec presence",
       ctx do
    owner = start(ctx, %{hooks: [hook("one", nil), hook("two", nil)], optional: nil})
    assert Enum.map(callbacks(owner).hooks, & &1.request) == [nil, nil]
  end

  test "native NewType hook arrays preserve mixed optional callback presence", ctx do
    owner =
      start(ctx, %{wrapped_hooks: [hook("with", &Fixture.Callbacks.add/2), hook("nil", nil)]})

    assert [first, second] = callbacks(owner).wrapped_hooks
    assert first.request.(8, 9) == 17
    assert second.request == nil
  end

  test "constrained map function nil retains native validation instead of being omitted", ctx do
    assert {:error, error} =
             Aikido.Durable.start(ctx.pool, Ash.UUIDv7.generate(),
               initial_state: %{callbacks: %{map_callback: %{callback: nil}}}
             )

    assert inspect(error, limit: :infinity) =~ "map_callback"
  end

  test "omitting the selected nil attribute cannot revive a paired codec string alias", ctx do
    owner = start(ctx, %{optional: nil, codec_alias?: true})
    assert callbacks(owner).optional == nil
  end

  test "required nil and explicit nil clearing a nonnil default retain native rejection", ctx do
    for field <- [:required, :defaulted] do
      id = Ash.UUIDv7.generate()
      result = Aikido.Durable.start(ctx.pool, id, initial_state: %{callbacks: %{field => nil}})
      assert {:error, error} = result
      assert inspect(error, limit: :infinity) =~ Atom.to_string(field)
    end
  end

  test "fresh stored capture strings fail before claim and the same public identity can retry",
       ctx do
    id = Ash.UUIDv7.generate()
    callback = &Fixture.Callbacks.add/2
    assert {:ok, stored} = Ash.Type.dump_to_embedded(:function, callback, mfa: true, arity: 2)

    result =
      Aikido.Durable.start(ctx.pool, id,
        initial_state: %{callbacks: %{hooks: [hook("nil", nil), hook("raw", stored)]}}
      )

    assert {:error, _} = result
    supervisor = ctx.pool
    assert :error = Aikido.Durable.lookup(supervisor, id)
    prefix = DurableServer.Supervisor.__get_config__(supervisor).prefix
    key = Aikido.Durable.storage_key(id, nil)

    assert {:error, :not_found} =
             DurableServer.fetch_stored_state(
               supervisor,
               %{key: key, prefix: prefix},
               consistent: true
             )

    owner = start(ctx, %{hooks: [hook("valid", callback), hook("nil", nil)]}, id)
    assert hd(callbacks(owner).hooks).request.(3, 4) == 7
  end

  defp start(ctx, callbacks, id \\ Ash.UUIDv7.generate()) do
    assert {:ok, pid} = Aikido.Durable.start(ctx.pool, id, initial_state: %{callbacks: callbacks})
    assert :ok = Aikido.AgentServer.await_ready(pid)
    %{id: id, pid: pid}
  end

  defp callbacks(owner) do
    assert {:ok, value} = Aikido.AgentServer.state(owner.pid, &{:ok, &1.agent.state.callbacks})
    value
  end

  defp hook(name, request),
    do: %{
      name: name,
      event: :before_model,
      script: "return {decision = 'continue'}",
      request: request
    }
end
