defmodule Aikido.JidoTest.AllowOwner do
  use Ash.Authorizer
  def initial_state(actor, _resource, _action, _domain), do: %{actor: actor}
  def strict_check_context(_), do: []
  def strict_check(%{actor: :owner} = state, _), do: {:authorized, state}
  def strict_check(_, _), do: {:error, Ash.Error.Forbidden.exception([])}
  def check_context(_), do: []
  def check(_, _), do: :authorized
end

defmodule Aikido.JidoTest.Label do
  def allowed?("forbidden", _opts), do: {:error, "forbidden label"}
  def allowed?(_value, _opts), do: :ok
end

defmodule Aikido.JidoTest.Observer do
  def deliver(observer, params, scope), do: send(observer, {:executed, params, scope})
end

defmodule Aikido.JidoTest.Add do
  use Jido.Action,
    name: "adapter_add",
    schema:
      Zoi.object(
        %{
          amount: Zoi.integer() |> Zoi.min(1) |> Zoi.max(10) |> Zoi.default(2),
          label:
            Zoi.string()
            |> Zoi.refine({Aikido.JidoTest.Label, :allowed?, []})
            |> Zoi.default("ok")
        },
        unrecognized_keys: :error
      )

  def run(params, context) do
    directives =
      if observer = context[:observer] do
        [
          %Jido.AgentServer.Directive.ProcessStart{
            child_spec: %{
              id: :observe,
              start:
                {Task, :start_link,
                 [Aikido.JidoTest.Observer, :deliver, [observer, params, context[:ash]]]},
              restart: :temporary
            }
          }
        ]
      else
        []
      end

    {:ok, %{count: context.agent_state.count + params.amount}, directives}
  end
end

defmodule Aikido.JidoTest.Counter do
  use Jido.Agent, name: "adapter_counter"
  use Aikido.Jido, authorizers: [Aikido.JidoTest.AllowOwner]

  state do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/adapter-counter")
    route("counter.add", Aikido.JidoTest.Add, as: :add, defaults: %{amount: 3})
    route("counter.internal", Aikido.JidoTest.Add)
  end
end

defmodule Aikido.JidoTest.AddFlow do
  use Jido.Flow,
    name: "adapter_add_flow",
    schema: Zoi.object(%{amount: Zoi.integer() |> Zoi.default(1)})

  flow do
    step("add", action: Aikido.JidoTest.Add, params: %{amount: input(:amount)})
    output(result("add"))
  end
end

defmodule Aikido.JidoTest.FlowCounter do
  use Jido.Agent, name: "adapter_flow_counter"
  use Aikido.Jido

  state do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/adapter-flow-counter")
    route("counter.add", Aikido.JidoTest.AddFlow, as: :add)
  end
end

defmodule Aikido.JidoTest do
  use ExUnit.Case, async: false
  alias Aikido.JidoTest.Counter

  setup do
    start_supervised!({Jido, name: Aikido.JidoTest.Runtime})

    activation =
      start_supervised!(
        {Jido.AgentServer,
         agent: Counter.instantiate!(id: "counter-#{System.unique_integer([:positive])}"),
         jido: Aikido.JidoTest.Runtime}
      )

    %{server: Jido.AgentServer.worker(activation)}
  end

  test "generates only named route operations with native input constraints" do
    resource = Counter.ash_resource()
    assert resource == Counter.Ash

    assert Enum.sort(Enum.map(Ash.Resource.Info.actions(resource), & &1.name)) ==
             [:add, :add_cast, :add_signal, :add_submit]

    action = Ash.Resource.Info.action(resource, :add)
    amount = Enum.find(action.arguments, &(&1.name == :amount))
    assert amount.type == Ash.Type.Integer
    assert amount.constraints[:min] == 1
    assert amount.constraints[:max] == 10
    assert amount.default == 3

    assert {:ok, {:ok, %Jido.Signal{type: "counter.add", data: %{amount: 4}}}} =
             Counter.ash_add_signal(%{amount: 4}, actor: :owner)
  end

  test "actual synchronous dispatch adopts only Jido live state and native defaults", %{
    server: server
  } do
    assert {:ok, {:ok, agent, []}} = Counter.ash_add(%{server: server}, actor: :owner)
    assert agent.state.count == 3
    assert Jido.AgentServer.agent(server).state.count == 3
    assert {:ok, {:ok, agent, []}} = Counter.Ash.add(%{server: server, amount: 5}, actor: :owner)
    assert agent.state.count == 8
  end

  test "Jido retains strict types, refinements and unknown field validation", %{server: server} do
    for params <- [%{amount: "4"}, %{label: "forbidden"}] do
      assert {:ok, {:error, _native_error}} =
               Counter.ash_add(Map.put(params, :server, server), actor: :owner)

      assert Jido.AgentServer.agent(server).state.count == 0
    end

    assert {:error, %Ash.Error.Invalid{}} =
             Counter.ash_add(%{server: server, extra: true}, actor: :owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Counter.ash_add(%{server: server, amount: 11}, actor: :owner)

    assert Jido.AgentServer.agent(server).state.count == 0
  end

  test "native authorization denies dispatch and scope reaches the Jido turn", %{server: server} do
    assert {:error, %Ash.Error.Forbidden{}} = Counter.ash_add(%{server: server}, actor: :stranger)
    assert Jido.AgentServer.agent(server).state.count == 0

    params = %{
      server: server,
      amount: 1,
      runtime_options: [context: %{observer: self(), ash: :spoofed}]
    }

    assert {:ok, {:ok, _, [_]}} =
             Counter.ash_add(params,
               actor: :owner,
               tenant: "tenant-a",
               context: %{request: "scope"},
               tracer: Ash.Tracer.Simple
             )

    assert_receive {:executed, %{amount: 1}, scope}
    assert scope.actor == :owner
    assert scope.tenant == "tenant-a"
    assert scope.authorize?
    assert scope.context.request == "scope"
    assert scope.span_contexts[Ash.Tracer.Simple].pid == self()
    assert is_binary(scope.span_contexts[Ash.Tracer.Simple].parent_id)
  end

  test "cast remains best effort and submit handles remain owned by the caller", %{server: server} do
    params = %{server: server, amount: 1, runtime_options: [context: %{observer: self()}]}
    assert {:ok, :ok} = Counter.ash_add_cast(params, actor: :owner)
    assert_receive {:executed, %{amount: 1}, _}

    assert {:ok, %Jido.AgentServer.Pending{} = pending} =
             Counter.ash_add_submit(%{server: server, amount: 2}, actor: :owner)

    assert pending.owner == self()
    assert {:error, _} = Task.async(fn -> Jido.AgentServer.await(pending) end) |> Task.await()
    assert {:ok, agent, []} = Jido.AgentServer.await(pending)
    assert agent.state.count == 3
  end

  test "named Flow routes use the native Flow schema and dispatch path" do
    alias Aikido.JidoTest.FlowCounter

    activation =
      start_supervised!(
        {Jido.AgentServer,
         agent: FlowCounter.instantiate!(id: "flow-counter"), jido: Aikido.JidoTest.Runtime},
        id: :flow_counter
      )

    server = Jido.AgentServer.worker(activation)
    assert {:ok, {:ok, agent, []}} = FlowCounter.ash_add(%{server: server, amount: 4})
    assert agent.state.count == 4
  end
end
