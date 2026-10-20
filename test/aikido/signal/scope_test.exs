defmodule Aikido.SignalScopeTest.Observe do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, context) do
    {:ok,
     %{
       actor: context.actor,
       tenant: context.tenant,
       authorize?: context.authorize?,
       tracer: context.tracer,
       application: input.context[:application],
       shared: input.context[:shared]
     }}
  end
end

defmodule Aikido.SignalScopeTest.Resource do
  use Ash.Resource,
    domain: Aikido.SignalScopeTest.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    action :observe, :map do
      run Aikido.SignalScopeTest.Observe
    end
  end
end

defmodule Aikido.SignalScopeTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Aikido.SignalScopeTest.Resource
  end
end

defmodule Aikido.SignalScopeTest do
  use ExUnit.Case, async: false
  require Ash.Tracer
  alias Aikido.Signal
  alias Aikido.SignalScopeTest.Resource
  alias AikidoTest.Support.TestTracer

  test "native actions and policies consume resolved signal scope without losing application context" do
    context = %{
      application: %{request: "scope-contract", settings: %{locale: "en"}},
      shared: %{request: %{source: "signal"}}
    }

    signal =
      Signal.new!(%{
        type: "scope.observe",
        scope: %{actor: %{id: "alice"}, tenant: "workspace", context: context, authorize?: true}
      })

    input = Ash.ActionInput.for_action(Resource, :observe, %{}, scope: signal)
    assert {:ok, observed} = Ash.run_action(input)
    assert observed.actor == %{id: "alice"}
    assert observed.tenant == "workspace"
    assert observed.authorize?
    assert observed.application == context.application
    assert observed.shared == context.shared

    denied = Ash.ActionInput.for_action(Resource, :observe, %{}, scope: signal, actor: nil)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(denied)

    anonymous = Signal.merge(signal, %{actor: nil, authorize?: false})
    assert {:ok, nil} = Ash.Scope.ToOpts.get_actor(anonymous)
    assert {:ok, false} = Ash.Scope.ToOpts.get_authorize?(anonymous)
    assert Keyword.has_key?(Ash.Scope.to_opts(anonymous), :actor)

    assert {:ok, %{actor: nil, authorize?: false}} =
             Resource
             |> Ash.ActionInput.for_action(:observe, %{}, scope: anonymous)
             |> Ash.run_action()
  end

  test "native casting and scope extraction remain pure and leave absent options absent" do
    literal = %Signal{
      type: "scope.literal",
      scope: %{actor: nil, authorize?: false, context: %{application: %{nested: [1, 2]}}}
    }

    assert {:ok, ^literal} = Signal.new(literal)
    assert {:ok, ^literal} = Ash.Type.cast_input(Signal, literal, [])
    assert {:ok, ^literal} = Ash.Type.cast_input(Signal, literal, [])

    assert Ash.Scope.to_opts(literal) == [
             actor: nil,
             context: %{application: %{nested: [1, 2]}},
             authorize?: false
           ]

    assert literal.id == nil
    assert literal.time == nil
    assert Ash.Scope.to_opts(%Signal{type: "scope.empty"}) == []
  end

  test "captured tracers participate in native actions after their span context is transferred" do
    start_supervised!(TestTracer)

    {signal, parent} =
      Ash.Tracer.span :custom, "signal.scope.parent", TestTracer do
        signal =
          %Signal{type: "scope.traced", scope: %{actor: %{id: "alice"}, tracer: TestTracer}}
          |> Signal.capture_tracing()
          |> Signal.delete(:tracer)

        {signal, TestTracer.get_span_context()}
      end

    assert Ash.Scope.to_opts(signal)[:tracer] == [TestTracer]
    assert signal.id == nil
    assert signal.time == nil

    task =
      Task.async(fn ->
        assert TestTracer.get_span_context() == nil
        Ash.ProcessHelpers.transfer_context(Signal.tracer_context(signal))
        options = Ash.Scope.to_opts(signal)

        Resource
        |> Ash.ActionInput.for_action(:observe, %{}, options)
        |> Ash.run_action(options)
      end)

    assert {:ok, observed} = Task.await(task)
    assert TestTracer in List.wrap(observed.tracer)

    events = TestTracer.get_spans()
    assert {:start, action, :action, _} = Enum.find(events, &match?({:start, _, :action, _}, &1))

    assert {:parent, ^action, ^parent, _} =
             Enum.find(events, &match?({:parent, ^action, _, _}, &1))
  end
end
