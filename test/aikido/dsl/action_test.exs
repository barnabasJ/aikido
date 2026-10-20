defmodule Aikido.NativeActionTest.CustomDirective do
  use Aikido.Directive

  typed_struct do
    field :value, :term
  end

  @impl true
  def exec(_directive, _signal, _runtime), do: :ok
end

defmodule Aikido.NativeActionTest.Actions.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :increment}} = input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(
      state: %{count: input.arguments.state.count + input.arguments.amount}
    )
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :emit}} = input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(state: %{count: 100}, directives: [input.arguments.directive])
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :prepared}} = input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :runtime}} = input,
        _opts,
        _context
      ) do
    runtime = input.context.aikido

    Aikido.Types.ActionResult.new(state: Map.take(runtime, [:agent_id, :signal, :slice_config]))
  end

  @impl true
  def run(
        %Ash.ActionInput{action: %{name: :invalid_result}} = _input,
        _opts,
        _context
      ) do
    Aikido.Types.ActionResult.new(state: %{}, directives: :invalid)
  end
end

defmodule Aikido.NativeActionTest.Actions do
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :increment, Aikido.Types.ActionResult do
      description "Increment typed state."
      argument :state, :map, allow_nil?: false
      argument :amount, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
      run Aikido.NativeActionTest.Actions.Implementation
    end

    action :emit, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :directive, :term, allow_nil?: false
      run Aikido.NativeActionTest.Actions.Implementation
    end

    action :prepared, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false

      prepare fn input, _context ->
        Ash.ActionInput.before_action(input, fn input ->
          Ash.ActionInput.set_argument(input, :state, %{prepared: true})
        end)
      end

      run Aikido.NativeActionTest.Actions.Implementation
    end

    action :runtime, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      run Aikido.NativeActionTest.Actions.Implementation
    end

    action :invalid_result, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      run Aikido.NativeActionTest.Actions.Implementation
    end
  end
end

defmodule Aikido.NativeActionTest do
  use ExUnit.Case, async: true

  defp run(action, params \\ %{}, context \\ %{state: %{count: 2}}) do
    signal =
      Map.get(context, :signal) ||
        struct!(Jido.Signal, id: nil, type: "test.action", data: params, source: "/test")

    signal = %{signal | data: params}
    runtime = Map.merge(Aikido.SignalCtx.ctx(signal), Map.get(context, :ctx, %{}))

    then(signal, fn signal ->
      Aikido.NativeActionTest.Actions
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
    assert Spark.Dsl.is?(Aikido.NativeActionTest.Actions, Ash.Resource)
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Actions, :increment).type == :action
  end

  test "actions have descriptive native names" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Actions, :increment).name ==
             :increment
  end

  test "descriptions are native Ash metadata" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Actions, :increment).description ==
             "Increment typed state."
  end

  test "actions declare the shared result type" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Actions, :increment).returns ==
             Aikido.Types.ActionResult
  end

  test "arguments retain native defaults" do
    assert Ash.Resource.Info.action(Aikido.NativeActionTest.Actions, :increment).arguments
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
      Ash.ActionInput.for_action(Aikido.NativeActionTest.Actions, :increment, %{
        state: %{count: 2},
        amount: 4
      })

    assert {:ok, %Aikido.Types.ActionResult{state: %{count: 6}}} = Ash.run_action(input)
  end

  test "runtime context preserves signal and mount configuration" do
    signal = Jido.Signal.new!("native.runtime", %{})

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
