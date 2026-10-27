defmodule Aikido.NativeActionTest.CustomDirective do
  use Aikido.Directive

  typed_struct do
    field :value, :term do
      description "Domain value used to verify state transitions and native contracts."
    end
  end

  @impl true
  def exec(_directive, _signal, _runtime), do: :ok
end

defmodule Aikido.NativeActionTest.Counter.Actions.Increment do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{count: input.arguments.state.count + input.arguments.amount}
    )
  end
end

defmodule Aikido.NativeActionTest.Counter.Actions.Emit do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{count: 100}, directives: [input.arguments.directive])
  end
end

defmodule Aikido.NativeActionTest.Counter.Actions.Prepared do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end

defmodule Aikido.NativeActionTest.Counter.Actions.Runtime do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    runtime = input.context.aikido

    Aikido.Types.ActionResult.new(state: Map.take(runtime, [:agent_id, :signal, :slice_config]))
  end
end

defmodule Aikido.NativeActionTest.Counter.Actions.InvalidResult do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{}, directives: :invalid)
  end
end

defmodule Aikido.NativeActionTest.Counter.Slice do
  use Aikido.Slice

  slice do
    name "native_action_counter"

    schema do
      attribute :count, :integer do
        description "Counter changed by the native action."
        default 0
      end

      attribute :prepared, :boolean do
        description "Whether the native preparation ran."
      end

      attribute :agent_id, :string do
        description "Agent identity observed by the reducer."
      end

      attribute :signal, :term do
        description "Signal observed by the reducer."
      end

      attribute :slice_config, :map do
        description "Mount configuration observed by the reducer."
      end
    end

    route "native.increment", :increment
    route "native.emit", :emit
    route "native.prepared", :prepared
    route "native.runtime", :runtime
    route "native.invalid_result", :invalid_result
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      description "Increment typed state."
      argument :state, :map, allow_nil?: false
      argument :amount, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
      run Aikido.NativeActionTest.Counter.Actions.Increment
    end

    action :emit, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :directive, :term, allow_nil?: false
      run Aikido.NativeActionTest.Counter.Actions.Emit
    end

    action :prepared, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false

      prepare fn input, _context ->
        Ash.ActionInput.before_action(input, fn input ->
          Ash.ActionInput.set_argument(input, :state, %{prepared: true})
        end)
      end

      run Aikido.NativeActionTest.Counter.Actions.Prepared
    end

    action :runtime, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      run Aikido.NativeActionTest.Counter.Actions.Runtime
    end

    action :invalid_result, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      run Aikido.NativeActionTest.Counter.Actions.InvalidResult
    end
  end
end

defmodule Aikido.NativeActionTest.Counter do
  use Aikido.Agent

  agent do
    name "native_action_counter"
    slice :counter, Aikido.NativeActionTest.Counter.Slice
  end
end

defmodule Aikido.NativeActionTest do
  use AikidoTest.Case, async: true

  test "native actions run through a mounted slice on a real agent", context do
    pid =
      start_server(context, Aikido.NativeActionTest.Counter,
        initial_state: %{counter: %{count: 2}}
      )

    signal = Aikido.Signal.new!("native.increment", %{amount: "3"})
    assert {:ok, 5} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state.counter.count})
  end

  defp run(action, params \\ %{}, context \\ %{state: %{count: 2}}) do
    signal =
      Map.get(context, :signal) ||
        %Aikido.Signal{id: nil, type: "test.action", data: params, source: "/test"}

    signal = %{signal | data: params}
    runtime = Map.merge(Aikido.Signal.ctx(signal), Map.get(context, :ctx, %{}))

    then(signal, fn signal ->
      Aikido.NativeActionTest.Counter.Slice
      |> Ash.ActionInput.for_action(
        action,
        Map.put(signal.data || %{}, :state, Map.get(context, :state, %{})),
        context: %{aikido: Map.put(runtime, :signal, signal)},
        skip_unknown_inputs: [:*]
      )
      |> Ash.run_action()
    end)
  end

  test "actions are native Ash definitions" do
    assert Spark.Dsl.is?(Aikido.NativeActionTest.Counter.Slice, Ash.Resource)

    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Counter.Slice, :increment).type ==
             :action
  end

  test "actions have descriptive native names" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Counter.Slice, :increment).name ==
             :increment
  end

  test "descriptions are native Ash metadata" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Counter.Slice, :increment).description ==
             "Increment typed state."
  end

  test "actions declare the shared result type" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Counter.Slice, :increment).returns ==
             Aikido.Types.ActionResult
  end

  test "arguments retain native defaults" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Counter.Slice, :increment).arguments
           |> Enum.find(&(&1.name == :amount))
           |> Map.fetch!(:default) == 1
  end

  test "native input casting coerces strings" do
    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 5}, directives: []}} =
             run(:increment, %{amount: "3"})
  end

  test "native defaults apply when arguments are omitted" do
    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 3}, directives: []}} = run(:increment)
  end

  test "native constraints reject invalid values" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{amount: 0})
  end

  test "native types reject invalid input" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{amount: "invalid"})
  end

  test "required state is checked by Ash" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{}, %{state: nil})
  end

  test "preparations and native before-action hooks execute" do
    assert {:ok, %Aikido.Types.ActionResult{state: %{prepared: true}, directives: []}} =
             run(:prepared)
  end

  test "results are a reusable Ash type" do
    assert Ash.Type.NewType.new_type?(Aikido.Types.ActionResult)

    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 1}, directives: []}} =
             Aikido.Types.ActionResult.new(state: %{count: 1})
  end

  test "known directives validate" do
    directive = Aikido.Directives.stop(:normal)

    assert {:ok, %Aikido.Types.ActionResult{directives: [^directive]}} =
             Aikido.Types.ActionResult.new(state: %{}, directives: [directive])
  end

  test "custom directive behaviours validate" do
    directive = %Aikido.NativeActionTest.CustomDirective{value: 1}

    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 100}, directives: [^directive]}} =
             run(:emit, %{directive: directive})
  end

  test "unknown structs are rejected as directives" do
    assert {:error, _} = run(:emit, %{directive: %URI{}})
  end

  test "plain maps are rejected as directives" do
    assert {:error, _} = run(:emit, %{directive: %{effect: :unknown}})
  end

  test "atoms are rejected as directives" do
    assert {:error, _} = run(:emit, %{directive: :unknown})
  end

  test "result constructors reject malformed directive lists" do
    assert {:error, _} = run(:invalid_result)
  end

  test "direct Ash callers can construct validated results" do
    input =
      Ash.ActionInput.for_action(Aikido.NativeActionTest.Counter.Slice, :increment, %{
        state: %{count: 2},
        amount: 4
      })

    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 6}}} = Ash.run_action(input)
  end

  test "runtime context preserves signal and mount configuration" do
    signal = Aikido.Signal.new!("native.runtime", %{})

    context = %{
      state: %{},
      signal: signal,
      ctx: %{agent_id: "agent", slice_config: %{label: "mount"}}
    }

    assert {:ok,
            %Aikido.Types.ActionResult{
              state: %{
                agent_id: "agent",
                signal: ^signal,
                slice_config: %{label: "mount"}
              },
              directives: []
            }} = run(:runtime, %{}, context)
  end
end
