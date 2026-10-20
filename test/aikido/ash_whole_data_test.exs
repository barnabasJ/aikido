defmodule AikidoTest.AshWholeDataTest.Reducer do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{received: input.arguments.data})
  end
end

defmodule AikidoTest.AshWholeDataTest.Agent do
  use Aikido.Agent

  agent do
    name "whole_data"
    instance AikidoTest.AshWholeDataTest.Instance

    schema do
      attribute :received, :term do
        description "Payload received by the selected native reducer."
        public? true
      end
    end

    signal :map_payload, "whole.map", :reduce_map
    signal :term_payload, "whole.term", :reduce_term
    signal :required_payload, "whole.required", :reduce_required
  end

  actions do
    action :reduce_map, Aikido.Types.ActionResult do
      public? false
      argument :state, :term

      argument :data, :map,
        default: %{amount: 7},
        allow_nil?: false,
        constraints: [preserve_nil_values?: true],
        description: "The entire payload"

      run AikidoTest.AshWholeDataTest.Reducer
    end

    action :reduce_term, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :data, :term, allow_nil?: true, description: "An arbitrary payload"
      run AikidoTest.AshWholeDataTest.Reducer
    end

    action :reduce_required, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshWholeDataTest.Reducer
    end
  end
end

defmodule AikidoTest.AshWholeDataTest do
  use ExUnit.Case, async: false

  alias AikidoTest.AshWholeDataTest.Agent, as: Resource

  setup do
    start_supervised!(
      {Aikido,
       name: AikidoTest.AshWholeDataTest.Instance, durable: AikidoTest.Case.durable_options()}
    )

    :ok
  end

  test "unflattened commands retain native data argument metadata and nil rules" do
    for {command, reducer} <- [
          map_payload: :reduce_map,
          term_payload: :reduce_term,
          required_payload: :reduce_required
        ] do
      source =
        Enum.find(Ash.Resource.Info.action(Resource, reducer).arguments, &(&1.name == :data))

      generated =
        Enum.find(Ash.Resource.Info.action(Resource, command).arguments, &(&1.name == :data))

      assert generated == %{source | public?: true}
    end

    assert input(:term_payload, %{data: nil}).valid?
    assert Map.get(input(:term_payload, %{}).arguments, :data) == nil
    refute input(:required_payload, %{data: nil}).valid?
    refute input(:required_payload, %{}).valid?

    flat = Spark.Dsl.Extension.get_persisted(Resource, :aikido_flat_signal_inputs, [])
    refute :map_payload in flat
    refute :term_payload in flat
  end

  test "a public command preserves a whole-map default through signal delivery" do
    reference = command!(:start, %{})
    assert %{status: :processed} = command!(:map_payload, %{agent: reference})
    assert %{received: %{amount: 7}} = command!(:inspect, %{agent: reference})

    payload = %{amount: 3, retained: nil, nested: %{key: "value"}}
    assert %{status: :processed} = command!(:map_payload, %{agent: reference, data: payload})
    assert %{received: ^payload} = command!(:inspect, %{agent: reference})
  end

  test "a public command accepts a native whole-data term instead of a replacement map" do
    reference = command!(:start, %{})
    payload = {:result, [1, 2]}
    assert %{status: :processed} = command!(:term_payload, %{agent: reference, data: payload})
    assert %{received: ^payload} = command!(:inspect, %{agent: reference})
  end

  test "whole-data commands retain false, explicit nil and omitted optional data" do
    reference = command!(:start, %{})

    for payload <- [false, nil, 0, "value"] do
      assert %{status: :processed} = command!(:term_payload, %{agent: reference, data: payload})
      assert %{received: ^payload} = command!(:inspect, %{agent: reference})
    end

    command!(:term_payload, %{agent: reference, data: :previous})
    assert %{status: :processed} = command!(:term_payload, %{agent: reference})
    assert %{received: nil} = command!(:inspect, %{agent: reference})
  end

  test "raw signals preserve scalar data at the native reducer boundary" do
    agent = Resource.initialize!()

    for payload <- [false, nil, 0, "value", {:result, 1}, %{key: nil}] do
      signal = Aikido.Signal.new!("whole.term", payload)

      assert {:ok, %{agent: updated}, []} =
               Aikido.AgentServer.apply_actions(
                 signal,
                 %{agent_module: Resource, agent: agent, agent_id: agent.id},
                 [{{Resource, :reduce_term}, payload}]
               )

      assert updated.state.state.received === payload
    end
  end

  defp input(action, arguments) do
    Ash.ActionInput.for_action(Resource, action, Map.put(arguments, :agent, "input-only"))
  end

  defp command!(action, arguments) do
    Resource |> Ash.ActionInput.for_action(action, arguments) |> Ash.run_action!()
  end
end
