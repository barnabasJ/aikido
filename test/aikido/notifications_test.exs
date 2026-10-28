defmodule Aikido.NotificationsTest.Signals.SetCount do
  use Aikido.Signal

  signal do
    type "notifications.set_count"

    schema do
      attribute :count, :integer do
        description "Counter value to publish after native state adoption."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.NotificationsTest.Actions.SetCount do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{count: input.arguments.count})
  end
end

defmodule Aikido.NotificationsTest.Signals.Rebind do
  use Aikido.Signal

  signal do
    type "notifications.rebind"

    schema do
      attribute :publisher_id, :string do
        description "New receiver-owned publisher binding."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.NotificationsTest.Actions.Rebind do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{publisher_id: input.arguments.publisher_id})
  end
end

defmodule Aikido.NotificationsTest.Counter do
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  slice do
    name "notification_counter"

    schema do
      attribute :count, :integer do
        description "Current counter value exposed by its explicit calculation."
        allow_nil? false
        default 0
      end
    end

    route Aikido.NotificationsTest.Signals.SetCount, Aikido.NotificationsTest.Actions.SetCount
  end

  calculations do
    calculate :notification_data, :integer, expr(count) do
      allow_nil? false
      field? false
    end
  end
end

defmodule Aikido.NotificationsTest.Private do
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  slice do
    name "private_notification_state"

    schema do
      attribute :secret, :string do
        description "Private state with no notification calculation."
        default "never published"
        sensitive? true
      end
    end
  end
end

defmodule Aikido.NotificationsTest.Actions.AdvanceRevision do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{revision: input.arguments.state.revision + 1})
  end
end

defmodule Aikido.NotificationsTest.Publisher do
  use Aikido.Agent

  agent do
    name "notification_publisher"

    schema do
      attribute :revision, :integer do
        description "Root projection included under the root state path."
        allow_nil? false
        default 0
      end
    end

    slice :counter, Aikido.NotificationsTest.Counter
    slice :private, Aikido.NotificationsTest.Private

    route Aikido.NotificationsTest.Signals.SetCount,
          Aikido.NotificationsTest.Actions.AdvanceRevision
  end

  calculations do
    calculate :notification_data, :integer, expr(revision) do
      allow_nil? false
    end
  end

  notifications do
    pubsub(Phoenix.PubSub)
    pubsub_name(Aikido.NotificationsTest.PubSub)

    publish :changed do
      topic(["notification-test", :id])
    end

    publish :audited do
      topic(["notification-test", :id])
    end
  end
end

defmodule Aikido.NotificationsTest.OrdinaryNotifierPublisher do
  use Aikido.Agent, notifiers: [Ash.Notifier.PubSub]

  agent do
    name "ordinary_notification_publisher"
  end

  calculations do
    calculate :notification_data, :integer, expr(1)
  end

  notifications do
    pubsub(Phoenix.PubSub)
    pubsub_name(Aikido.NotificationsTest.PubSub)

    publish :changed do
      topic(["ordinary-notifier-test", :id])
    end
  end
end

defmodule Aikido.NotificationsTest.Scope do
  def resolve(agent) do
    {:ok,
     %{
       actor: %{id: agent.state.state.receiving_actor},
       tenant: "receiver-tenant"
     }}
  end
end

defmodule Aikido.NotificationsTest.Actions.RecordProjection do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    Aikido.Types.ActionResult.new(
      changes: %{
        count: input.arguments.data.counter,
        revision: input.arguments.data.state,
        received_actor: context.actor,
        received_tenant: context.tenant
      }
    )
  end
end

defmodule Aikido.NotificationsTest.Receiver do
  use Aikido.Agent

  agent do
    name "notification_receiver"

    schema do
      attribute :publisher_id, :string do
        description "Publisher identity whose topic this receiver is permitted to join."
      end

      attribute :receiving_actor, :string do
        description "Receiver-owned authority resolved for incoming publications."
        default "receiver-authority"
      end

      attribute :count, :integer do
        description "Most recently observed published counter."
        default 0
      end

      attribute :revision, :integer do
        description "Most recently observed published root revision."
        default 0
      end

      attribute :received_actor, :term do
        description "Actual native receiving action actor."
      end

      attribute :received_tenant, :string do
        description "Actual native receiving action tenant."
      end
    end

    route Aikido.NotificationsTest.Publisher.Signals.Changed, :record_projection, public?: false

    route Aikido.NotificationsTest.Publisher.Signals.Audited, :record_audit, public?: false

    route Aikido.NotificationsTest.Signals.Rebind, Aikido.NotificationsTest.Actions.Rebind
  end

  actions do
    action :record_projection, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, Aikido.NotificationsTest.Publisher.Signals.Changed, allow_nil?: false
      run Aikido.NotificationsTest.Actions.RecordProjection
    end

    action :record_audit, Aikido.Types.ActionResult do
      public? false
      argument :state, :term, allow_nil?: false
      argument :data, Aikido.NotificationsTest.Publisher.Signals.Audited, allow_nil?: false
      run Aikido.NotificationsTest.Actions.RecordProjection
    end
  end

  notifications do
    scope({Aikido.NotificationsTest.Scope, :resolve, []})

    subscribe Aikido.NotificationsTest.Publisher, :changed do
      bindings(id: :publisher_id)
    end

    subscribe Aikido.NotificationsTest.Publisher, :audited do
      bindings(id: :publisher_id)
    end
  end
end

defmodule Aikido.NotificationsTest do
  use AikidoTest.Case, async: false

  alias Aikido.NotificationsTest.{Publisher, Receiver, Signals}

  setup do
    start_supervised!({Phoenix.PubSub, name: Aikido.NotificationsTest.PubSub})
    :ok
  end

  test "native PubSub is registered once across ordinary and simple notifiers" do
    for resource <- [Publisher, Aikido.NotificationsTest.OrdinaryNotifierPublisher] do
      assert Enum.count(Ash.Resource.Info.notifiers(resource), &(&1 == Ash.Notifier.PubSub)) == 1
    end
  end

  test "Aikido publications reject conflicting native PubSub configuration" do
    assert_raise Spark.Error.DslError, ~r/Do not combine Aikido publications/, fn ->
      Code.compile_string("""
      defmodule Aikido.NotificationsTest.ConflictingPublisher do
        use Aikido.Agent, notifiers: [Ash.Notifier.PubSub]

        agent do
          name "conflicting_notification_publisher"
        end

        pub_sub do
          module Phoenix.PubSub
          name Aikido.NotificationsTest.PubSub
          prefix "existing"
          publish :__aikido_apply_state__, ["native", :id]
        end

        notifications do
          pubsub Phoenix.PubSub
          pubsub_name Aikido.NotificationsTest.PubSub

          publish :changed do
            topic ["generated", :id]
          end
        end
      end
      """)
    end
  end

  test "native publication composes explicit root and slice calculations and reaches an agent under receiving scope",
       context do
    publisher_id = unique_id("publisher")
    topic = "notification-test:" <> publisher_id
    :ok = Phoenix.PubSub.subscribe(Aikido.NotificationsTest.PubSub, topic)

    receiver = start_server(context, Receiver, initial_state: %{publisher_id: publisher_id})
    await_registration(receiver)
    publisher = start_server(context, Publisher, id: publisher_id)

    signal =
      Signals.SetCount.new!(%{count: 7})
      |> Aikido.Signal.put(:actor, %{id: "publisher-authority"})
      |> Aikido.Signal.put(:tenant, "publisher-tenant")

    assert {:ok, _} = Aikido.AgentServer.call(publisher, signal, &{:ok, &1.agent.state})

    assert_receive %{topic: ^topic, event: "changed", payload: %{counter: 7, state: 1} = payload}
    assert Enum.sort(Map.keys(payload)) == [:counter, :state]
    refute Map.has_key?(payload, :private)

    state =
      await_state_value(receiver, fn runtime ->
        state = runtime.agent.state.state
        if state.count == 7 && state.revision == 1, do: state
      end)

    assert state.revision == 1
    assert state.received_actor == %{id: "receiver-authority"}
    assert state.received_tenant == "receiver-tenant"

    definition = Aikido.Notifications.Info.signal(Publisher, :changed)
    assert {:ok, _} = definition.new(payload)
    assert {:error, _} = definition.new(%{counter: "invalid", state: 1})
  end

  test "malformed matching broadcasts cannot update the receiving agent", context do
    publisher_id = unique_id("publisher")
    receiver = start_server(context, Receiver, initial_state: %{publisher_id: publisher_id})
    await_registration(receiver)

    :ok =
      Phoenix.PubSub.broadcast(
        Aikido.NotificationsTest.PubSub,
        "notification-test:" <> publisher_id,
        %{
          topic: "notification-test:" <> publisher_id,
          event: "changed",
          payload: %{counter: "invalid", state: 1}
        }
      )

    assert {:ok, state} = Aikido.AgentServer.state(receiver, &{:ok, &1.agent.state.state})
    assert state.count == 0
    assert state.received_actor == nil
    assert Process.alive?(receiver)
  end

  test "two publication events share one actual topic membership", context do
    publisher_id = unique_id("publisher")
    topic = "notification-test:" <> publisher_id
    receiver = start_server(context, Receiver, initial_state: %{publisher_id: publisher_id})
    registrations = await_registration(receiver)
    assert length(registrations) == 2
    assert [{^receiver, _metadata}] = Registry.lookup(Aikido.NotificationsTest.PubSub, topic)

    changed = Aikido.Signal.Info.signal_type!(Publisher.Signals.Changed)
    audited = Aikido.Signal.Info.signal_type!(Publisher.Signals.Audited)
    selector = fn runtime -> {:ok, runtime.agent.state.state.count} end

    assert {:ok, changed_ref} =
             Aikido.AgentServer.subscribe(receiver, changed, selector, once: true)

    assert {:ok, audited_ref} =
             Aikido.AgentServer.subscribe(receiver, audited, selector, once: true)

    for event <- ["changed", "audited"] do
      :ok =
        Phoenix.PubSub.broadcast(Aikido.NotificationsTest.PubSub, topic, %{
          topic: topic,
          event: event,
          payload: %{counter: 9, state: 2}
        })
    end

    assert_receive {:aikido_subscription, ^changed_ref, %{result: {:ok, 9}}}
    assert_receive {:aikido_subscription, ^audited_ref, %{result: {:ok, 9}}}
  end

  test "changed receiver bindings reject an old topic until subscriptions are rebuilt", context do
    publisher_id = unique_id("publisher")
    topic = "notification-test:" <> publisher_id
    receiver = start_server(context, Receiver, initial_state: %{publisher_id: publisher_id})
    await_registration(receiver)

    signal = Signals.Rebind.new!(%{publisher_id: unique_id("replacement")})
    assert {:ok, _} = Aikido.AgentServer.call(receiver, signal, &{:ok, &1.agent.state})
    assert {:ok, agent} = Aikido.AgentServer.state(receiver, &{:ok, &1.agent})
    message = %{topic: topic, event: "changed", payload: %{counter: 9, state: 2}}

    assert {:error, :notification_bindings_changed} =
             Aikido.Notifications.Receiver.receive_message(message, agent)

    :ok = Phoenix.PubSub.broadcast(Aikido.NotificationsTest.PubSub, topic, message)
    assert {:ok, state} = Aikido.AgentServer.state(receiver, &{:ok, &1.agent.state.state})
    assert state.count == 0
    assert state.received_actor == nil
  end

  test "missing subscription binding fails activation before ready", context do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:aikido, :agent_server, :ready],
        &__MODULE__.observe_ready/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, reason} = start_test_agent(context, Receiver, restart?: false)
    assert inspect(reason) =~ "missing_notification_binding"
    refute_received {:notification_agent_ready, Receiver}
  end

  def observe_ready(_event, _measurements, metadata, observer) do
    send(observer, {:notification_agent_ready, metadata.agent_module})
  end

  defp await_registration(receiver) do
    await_state_value(receiver, fn runtime ->
      case runtime.agent.state.notifications.registrations do
        [_ | _] = registrations -> registrations
        _ -> nil
      end
    end)
  end
end
