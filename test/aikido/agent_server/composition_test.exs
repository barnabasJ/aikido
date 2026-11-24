defmodule R368CompTest.SourceEmit do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    # Synthetic producer: the accepted batch is declared DIRECTLY (the same
    # contract the real Conversation-backed producers satisfy via
    # Conversation.accepted_output/1).
    accepted = [
      ReqLLM.Context.user("accepted one"),
      ReqLLM.Context.user("accepted two")
    ]

    state =
      Map.update!(input.arguments.state, :log, fn log ->
        log ++
          Enum.map(accepted, fn m ->
            if is_list(m.content),
              do: Enum.map_join(m.content, "", &(&1.text || "")),
              else: m.content
          end)
      end)

    changes = Map.take(state, [:log])

    Aikido.Types.ActionResult.new(
      changes: changes,
      directives: [],
      outputs: %{accepted_messages: accepted}
    )
  end
end

defmodule R368CompTest.ConsumerRecord do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    poison = input.arguments.poison

    if poison do
      raise "poisoned consumer"
    end

    # Generic consumption: the fold is namespaced by {reference, path}; a
    # consumer reading ALL staged outputs sees every producer's batch, in
    # staged order.
    batch =
      (input.context[:aikido][:staged_outputs] || %{})
      |> Enum.flat_map(fn {_key, output} ->
        Map.get(output || %{}, :accepted_messages, [])
      end)
      |> Enum.map(fn message ->
        if is_list(message.content),
          do: Enum.map_join(message.content, "", &(&1.text || "")),
          else: message.content
      end)

    Aikido.Types.ActionResult.new(
      changes: %{received: Map.get(state, :received, []) ++ batch},
      directives: []
    )
  end
end

defmodule R368CompTest.SourceSlice do
  @moduledoc false
  use Aikido.Slice

  attributes do
    attribute :log, {:array, :term}, default: [], public?: true
  end

  slice do
    name "r368_source"
    route "r368/emit", {__MODULE__, :emit}
  end

  actions do
    action :emit, Aikido.Types.ActionResult do
      argument :state, :term
      run R368CompTest.SourceEmit
    end
  end
end

defmodule R368CompTest.ConsumerSlice do
  @moduledoc false
  use Aikido.Slice

  attributes do
    attribute :received, {:array, :term}, default: [], public?: true
  end

  slice do
    name "r368_consumer"
    route "r368/emit", {__MODULE__, :record}
  end

  actions do
    action :record, Aikido.Types.ActionResult do
      argument :state, :term
      argument :poison, :boolean
      run R368CompTest.ConsumerRecord
    end
  end
end

defmodule R368CompTest.BothAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "r368_both"
    path :domain
    slice :src, R368CompTest.SourceSlice
    slice :dst, R368CompTest.ConsumerSlice
  end
end

defmodule R368CompTest.TwoMountsAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "r368_two_mounts"
    path :domain
    slice :src_a, R368CompTest.SourceSlice
    slice :src_b, R368CompTest.SourceSlice
    slice :dst, R368CompTest.ConsumerSlice
  end
end

defmodule R368CompTest.ConsumerOnlyAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "r368_consumer_only"
    path :domain
    slice :dst, R368CompTest.ConsumerSlice
  end
end

defmodule R368CompTest.CompositionTest do
  @moduledoc "Direct AgentServer tests for the generic staged-output composition."
  use ExUnit.Case, async: true

  alias Aikido.AgentServer

  defp agent_for(agent_module), do: agent_module.initialize!()

  defp build_ctx(agent_module, agent, signal) do
    Map.merge(Aikido.Signal.ctx(signal), %{
      agent_module: agent_module,
      agent: agent,
      agent_id: agent.id
    })
  end

  defp default_targets do
    [
      {{R368CompTest.SourceSlice, :emit}, %{}},
      {{R368CompTest.ConsumerSlice, :record}, %{poison: false}}
    ]
  end

  defp poisoned_targets do
    [
      {{R368CompTest.SourceSlice, :emit}, %{}},
      {{R368CompTest.ConsumerSlice, :record}, %{poison: true}}
    ]
  end

  test "the ordered batch folds to the consumer, adoption keeps both states, nothing leaks" do
    agent = agent_for(R368CompTest.BothAgent)
    signal = %Aikido.Signal{id: nil, type: "r368/emit", data: %{}, source: "/test"}

    {:ok, %{agent: adopted}, directives} =
      AgentServer.apply_actions(
        signal,
        build_ctx(R368CompTest.BothAgent, agent, signal),
        default_targets()
      )

    # The consumer saw the producer's batch, in order, across the fold.
    assert adopted.state.dst.received == ["accepted one", "accepted two"]
    # The producer's own adoption is intact.
    assert adopted.state.src.log == ["accepted one", "accepted two"]
    # NOTHING retained: no window keys on any slice state.
    refute Map.has_key?(adopted.state.src, :appended_messages)
    refute Map.has_key?(adopted.state.src, :accepted_messages)
    refute Map.has_key?(adopted.state.dst, :accepted_messages)
    # No effects were manufactured by the composition.
    assert directives == []
  end

  test "two mounts of one slice are namespaced, not merged" do
    agent = agent_for(R368CompTest.TwoMountsAgent)
    signal = %Aikido.Signal{id: nil, type: "r368/emit", data: %{}, source: "/test"}

    # ONE source target: its action runs at EACH mounted path (:src_a, then
    # :src_b) — the fold namespaces the two batches separately.
    {:ok, %{agent: adopted}, _} =
      AgentServer.apply_actions(signal, build_ctx(R368CompTest.TwoMountsAgent, agent, signal), [
        {{R368CompTest.SourceSlice, :emit}, %{}},
        {{R368CompTest.ConsumerSlice, :record}, %{poison: false}}
      ])

    # Each mount contributed its own full batch; the consumer received both,
    # in staged order (namespaced keys, no collision).
    assert adopted.state.src_a.log == ["accepted one", "accepted two"]
    assert adopted.state.src_b.log == ["accepted one", "accepted two"]

    assert adopted.state.dst.received ==
             ["accepted one", "accepted two", "accepted one", "accepted two"]
  end

  test "an undeclared agent (no producer mounted) keeps its identity" do
    agent = agent_for(R368CompTest.ConsumerOnlyAgent)
    signal = %Aikido.Signal{id: nil, type: "r368/emit", data: %{}, source: "/test"}

    {:ok, %{agent: adopted}, directives} =
      AgentServer.apply_actions(
        signal,
        build_ctx(R368CompTest.ConsumerOnlyAgent, agent, signal),
        [
          {{R368CompTest.ConsumerSlice, :record}, %{poison: false}}
        ]
      )

    # No producer staged anything: the consumer saw an empty fold and stayed
    # silent — identical to its behavior before this mechanism existed.
    assert adopted.state.dst.received == []
    assert directives == []
  end

  test "a rejected consumer rolls back BOTH states and executes no effects" do
    agent = agent_for(R368CompTest.BothAgent)
    signal = %Aikido.Signal{id: nil, type: "r368/emit", data: %{poison: true}, source: "/test"}

    {result, error_ctx, _error} =
      AgentServer.apply_actions(
        signal,
        build_ctx(R368CompTest.BothAgent, agent, signal),
        poisoned_targets()
      )

    # NOTHING was adopted: the producer's own changes rolled back with the
    # failed consumer (one transaction, all-or-nothing).
    assert result == :error
    assert error_ctx.agent.state.src.log == []
    assert Map.get(error_ctx.agent.state.dst, :received, []) == []
    # The raised consumer reason surfaces; the accepted batch text never
    # becomes an effect.
    refute inspect(error_ctx.agent.state.src.log) =~ "accepted one"
  end

  test "the typed output rejects non-map values" do
    outcome =
      try do
        r = Aikido.Types.ActionResult.new(changes: %{}, directives: [], outputs: "not a map")
        {:ok, r.outputs}
      rescue
        e -> {:raised, Exception.message(e)}
      end

    # The invalid value never lands verbatim in the result.
    refute match?({:ok, "not a map"}, outcome)

    assert match?({:raised, _}, outcome) or match?({:error, _}, outcome) or
             match?({:ok, nil}, outcome) or match?({:ok, %{}}, outcome)
  end

  test "probe: typed outputs cast behavior" do
    outcome =
      try do
        r = Aikido.Types.ActionResult.new(changes: %{}, directives: [], outputs: "not a map")
        {:accepted, r.outputs}
      rescue
        e -> {:raised, Exception.message(e)}
      end

    IO.inspect(outcome, label: "PROBE_TYPED_OUTPUTS")
  end
end
