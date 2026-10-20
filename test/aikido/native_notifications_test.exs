defmodule Aikido.NativeNotificationsTest.Notifier do
  use Ash.Notifier

  @impl true
  def notify(%{metadata: %{observer: observer}} = notification) when is_pid(observer) do
    send(
      observer,
      {:native_notification, self(), notification,
       AikidoTest.Support.TestTracer.get_span_context()}
    )

    if notification.metadata[:block] do
      receive do
        :release -> :ok
      end
    end

    :ok
  end

  def notify(_notification), do: :ok
end

defmodule Aikido.NativeNotificationsTest.Reducer do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    notification = %Ash.Notifier.Notification{
      resource: Aikido.NativeNotificationsTest.Agent,
      data: %Aikido.Signal{type: "notification.committed", data: 42},
      metadata: %{observer: input.arguments.observer, block: true}
    }

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | count: input.arguments.state.count + 1},
      directives: [%Aikido.Directives.Notify{notification: notification}]
    )
  end
end

defmodule Aikido.NativeNotificationsTest.Agent do
  use Aikido.Agent, notifiers: [Aikido.NativeNotificationsTest.Notifier]

  agent do
    name "native_notifications"

    schema do
      attribute :count, :integer, default: 0
    end

    route "notify.commit", :commit
  end

  actions do
    action :commit, Aikido.Types.ActionResult do
      argument :state, :term
      argument :observer, :term, allow_nil?: false
      run Aikido.NativeNotificationsTest.Reducer
    end
  end
end

defmodule Aikido.NativeNotificationsTest do
  use AikidoTest.Case, async: false
  require Ash.Tracer

  test "application-configured native notifier observes committed state in supervised work",
       context do
    start_supervised!(AikidoTest.Support.TestTracer)
    pid = start_server(context, Aikido.NativeNotificationsTest.Agent)

    signal =
      Aikido.Signal.new!("notify.commit", %{observer: self()})
      |> Aikido.Signal.put_ctx(%{
        actor: %{id: "caller"},
        tenant: "workspace",
        context: %{request: :native},
        tracer: AikidoTest.Support.TestTracer
      })

    Ash.Tracer.span :custom, "native.notification", AikidoTest.Support.TestTracer do
      assert :ok = Aikido.AgentServer.cast(pid, signal)
    end

    assert_receive {:native_notification, worker, notification, trace_context}
    on_exit(fn -> if Process.alive?(worker), do: send(worker, :release) end)
    refute worker == pid
    assert notification.from == worker
    assert notification.actor == %{id: "caller"}
    assert notification.resource == Aikido.NativeNotificationsTest.Agent
    assert notification.data.data == 42
    assert is_binary(notification.data.id)
    assert is_binary(notification.data.time)
    assert notification.data.scope.actor == %{id: "caller"}
    assert notification.data.scope.tenant == "workspace"
    assert notification.data.scope.context.request == :native
    assert trace_context != nil
    assert notification.data.tracer_context != %{}
    assert {:ok, 1} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.count})
    send(worker, :release)
  end

  test "native notifications retain explicit actors and default missing actors from signal scope",
       context do
    source =
      Aikido.Signal.new!("notification.request", %{})
      |> Aikido.Signal.put(:actor, %{id: "caller"})

    runtime = %Aikido.AgentServer.State{
      id: "notify",
      agent_module: Aikido.NativeNotificationsTest.Agent,
      agent: %{},
      aikido: context.aikido
    }

    for {actor, expected} <- [{nil, %{id: "caller"}}, {%{id: "explicit"}, %{id: "explicit"}}] do
      notification = %Ash.Notifier.Notification{
        for: Aikido.NativeNotificationsTest.Notifier,
        actor: actor,
        data: [:arbitrary, 42],
        metadata: %{observer: self()}
      }

      assert :ok =
               Aikido.Directive.exec(
                 %Aikido.Directives.Notify{notification: notification},
                 source,
                 runtime
               )

      assert_receive {:native_notification, _, delivered, _}
      assert delivered.actor == expected
      assert delivered.data == [:arbitrary, 42]
    end
  end

  test "pure native broadcast descriptor publishes through application-owned Phoenix PubSub",
       context do
    pubsub = Aikido.NativeNotificationsTest.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    :ok = Phoenix.PubSub.subscribe(pubsub, "application.events")

    source =
      Aikido.Signal.new!("broadcast.request", %{}) |> Aikido.Signal.put(:tenant, "workspace")

    state = %{count: 4}

    input =
      Ash.ActionInput.for_action(
        Aikido.AgentServer.RuntimeActions,
        :broadcast,
        %{
          state: state,
          pubsub: pubsub,
          topic: "application.events",
          signal_type: "broadcast.ready",
          payload: %{answer: 42}
        },
        context: %{aikido: %{signal: source}}
      )

    assert {:ok, %Aikido.Types.ActionResult{state: ^state, directives: [directive]}} =
             Ash.run_action(input)

    assert %Aikido.Directives.Notify{notification: notification} = directive
    assert notification.for == Aikido.Notifiers.PubSub
    assert notification.data.id == nil
    refute_received %Aikido.Signal{type: "broadcast.ready"}

    runtime = %Aikido.AgentServer.State{
      id: "notify",
      agent_module: Aikido.NativeNotificationsTest.Agent,
      agent: %{},
      aikido: context.aikido
    }

    assert :ok = Aikido.Directive.exec(directive, source, runtime)

    assert_receive %Aikido.Signal{
                     type: "broadcast.ready",
                     data: %{answer: 42},
                     scope: %{tenant: "workspace"}
                   } = delivered

    assert is_binary(delivered.id)
    assert is_binary(delivered.time)
  end
end
