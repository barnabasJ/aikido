defmodule Aikido.StateAdoptionTest.Signals.Propose do
  use Aikido.Signal

  signal do
    type "state.propose"

    schema do
      attribute :count, :term do
        description "Deliberately untyped input used to exercise reducer-output validation."
      end

      attribute :observer, :term do
        description "Test observer receiving the post-adoption effect."
        allow_nil? false
      end

      attribute :nil_changes?, :boolean do
        description "Return nil changes to leave the slice unchanged."
        default false
      end

      attribute :fail_second?, :boolean do
        description "Reject the second mount after the first mount has staged a valid update."
        default false
      end

      attribute :gate?, :boolean do
        description "Pause middleware before state adoption for notification ordering assertions."
        default false
      end
    end
  end
end

defmodule Aikido.StateAdoptionTest.Signals.InstallCallback do
  use Aikido.Signal

  signal do
    type "state.install_callback"

    schema do
      attribute :callback, :term do
        description "Transient function installed through a live agent action."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.StateAdoptionTest.Actions.InstallCallback do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{callback: input.arguments.callback})
  end
end

defmodule Aikido.StateAdoptionTest.Actions.ProposeCounter do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    count =
      if input.arguments.fail_second? && input.context.aikido.slice_path == :other_counter,
        do: -1,
        else: input.arguments.count

    if input.arguments.nil_changes? do
      effect =
        Aikido.Directives.emit_to_pid(
          %Aikido.Signal{
            type: "state.nil_unchanged",
            data: %{path: input.context.aikido.slice_path}
          },
          input.arguments.observer
        )

      Aikido.Types.ActionResult.new(changes: nil, directives: [effect])
    else
      Aikido.Types.ActionResult.new(changes: %{count: count, observer: input.arguments.observer})
    end
  end
end

defmodule Aikido.StateAdoptionTest.SliceNotifier do
  use Ash.Notifier

  @impl true
  def notify(notification) do
    if observer = notification.data.observer do
      send(observer, {:slice_notification, notification})
    end

    :ok
  end
end

defmodule Aikido.StateAdoptionTest.Counter do
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension],
    notifiers: [Aikido.StateAdoptionTest.SliceNotifier]

  actions do
    destroy :destroy do
      primary? true
    end
  end

  slice do
    name "state_adoption_counter"

    schema do
      attribute :count, :integer do
        description "Validated nonnegative counter."
        allow_nil? false
        default 0
        constraints min: 0
      end

      attribute :observer, :term do
        description "Observer for native embedded update notifications."
      end

      attribute :callback, :term do
        description "Transient function preserved by native state adoption."
      end
    end

    route Aikido.StateAdoptionTest.Signals.Propose,
          Aikido.StateAdoptionTest.Actions.ProposeCounter

    route Aikido.StateAdoptionTest.Signals.InstallCallback,
          Aikido.StateAdoptionTest.Actions.InstallCallback
  end

  @doc false
  def externalize(state), do: Map.put(state, :callback, nil)

  @doc false
  def reinstate(state), do: state
end

defmodule Aikido.StateAdoptionTest.Notifier do
  use Ash.Notifier

  @impl true
  def notify(%{data: %{runtime_pid: pid, observer: observer}} = notification)
      when is_pid(pid) and is_pid(observer) do
    send(observer, {:state_notification, self(), notification})
    {:ok, count} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.counter.count})
    send(observer, {:notification_observed_adopted_count, count})
    :ok
  end

  def notify(_notification), do: :ok
end

defmodule Aikido.StateAdoptionTest.Gate do
  use Aikido.Middleware

  @impl true
  def on_signal(signal, ctx, _opts, next) do
    result = next.(signal, ctx)

    if signal.type == "state.propose" && signal.data[:gate?] && match?({:ok, _, _}, result) do
      send(signal.data.observer, {:state_staged, self()})

      receive do
        :adopt_state -> :ok
      after
        10_000 -> raise "State-adoption test gate was not released"
      end
    end

    result
  end
end

defmodule Aikido.StateAdoptionTest.Actions.RecordAttempt do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    effect =
      Aikido.Directives.emit_to_pid(
        %Aikido.Signal{type: "state.adopted", data: %{}},
        input.arguments.observer
      )

    Aikido.Types.ActionResult.new(
      changes: %{
        attempts: input.arguments.state.attempts + 1,
        observer: input.arguments.observer,
        runtime_pid: input.context.aikido.agent_pid
      },
      directives: [effect]
    )
  end
end

defmodule Aikido.StateAdoptionTest.Agent do
  use Aikido.Agent, notifiers: [Aikido.StateAdoptionTest.Notifier]

  agent do
    name "state_adoption"
    middleware [Aikido.StateAdoptionTest.Gate]

    schema do
      attribute :attempts, :integer do
        description "Own-state changes rolled back when a mounted proposal is invalid."
        default 0
      end

      attribute :observer, :term do
        description "Observer for post-adoption native notifications."
      end

      attribute :runtime_pid, :term do
        description "Runtime identity used to assert the notification observes adopted state."
      end
    end

    slice :counter, Aikido.StateAdoptionTest.Counter
    slice :other_counter, Aikido.StateAdoptionTest.Counter
    route Aikido.StateAdoptionTest.Signals.Propose, Aikido.StateAdoptionTest.Actions.RecordAttempt
  end
end

defmodule Aikido.StateAdoptionTest do
  use AikidoTest.Case, async: false
  alias Aikido.StateAdoptionTest.{Agent, Signals}

  test "a reducer-returned changes map is validated and the complete signal rolls back on failure",
       context do
    pid = start_server(context, Agent)

    for invalid <- [-1, "not an integer", nil] do
      # The signal accepts arbitrary values so rejection happens at the
      # proposed-state update, rather than in the command's input casting.
      signal = Aikido.Signal.new!("state.propose", %{count: invalid, observer: self()})
      assert {:error, _} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
      assert {:ok, state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
      assert state.state.attempts == 0
      assert state.counter.count == 0
      assert state.other_counter.count == 0
      refute_received {:signal, %Aikido.Signal{type: "state.adopted"}}
      refute_received {:state_notification, _, _}
      refute_received {:slice_notification, _}
    end
  end

  test "nil changes leave mounted slices unchanged and executes returned directives", context do
    tracer = AikidoTest.Support.TestTracer
    start_supervised!(tracer)
    observer = self()
    pid = start_server(context, Agent, initial_state: %{counter: %{observer: observer}})

    assert_receive {:slice_notification,
                    %{
                      resource: Aikido.StateAdoptionTest.Counter,
                      action: %{name: :create, type: :create},
                      data: %Aikido.StateAdoptionTest.Counter{observer: ^observer}
                    }}

    signal =
      Signals.Propose.new!(%{count: 7, observer: self(), nil_changes?: true})
      |> Aikido.Signal.put(:tracer, tracer)

    assert {:ok, state} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
    assert %Aikido.StateAdoptionTest.Counter{count: 0} = state.counter
    assert %Aikido.StateAdoptionTest.Counter{count: 0} = state.other_counter
    assert state.state.attempts == 1
    assert_receive {:signal, %Aikido.Signal{type: "state.adopted"}}
    assert_receive {:signal, %Aikido.Signal{type: "state.nil_unchanged", data: %{path: :counter}}}

    assert_receive {:signal,
                    %Aikido.Signal{type: "state.nil_unchanged", data: %{path: :other_counter}}}

    spans = tracer.get_spans()

    reducer_spans =
      Enum.filter(spans, fn
        {:metadata, _, :action, %{resource: Aikido.StateAdoptionTest.Counter, action: :propose}} ->
          true

        _ ->
          false
      end)

    assert length(reducer_spans) == 2

    refute Enum.any?(spans, fn
             {:metadata, _, :action,
              %{resource: Aikido.StateAdoptionTest.Counter, action: action}}
             when action in [:update, :__aikido_apply_state__] ->
               true

             _ ->
               false
           end)

    refute Enum.any?(spans, fn
             {:metadata, _, :action,
              %{resource: Aikido.StateAdoptionTest.Counter, action: :destroy}} ->
               true

             _ ->
               false
           end)

    refute_received {:slice_notification, _}
  end

  test "a later failed mount discards earlier embedded notifications and state", context do
    pid = start_server(context, Agent)
    signal = Signals.Propose.new!(%{count: 7, observer: self(), fail_second?: true})

    assert {:error, _} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
    assert {:ok, state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
    assert state.state.attempts == 0
    assert state.counter.count == 0
    assert state.other_counter.count == 0
    refute_received {:state_notification, _, _}
    refute_received {:slice_notification, _}
    refute_received {:signal, %Aikido.Signal{type: "state.adopted"}}
  end

  test "native update casts sparse values without resetting omitted attributes", context do
    callback = fn value -> value + 1 end
    pid = start_server(context, Agent)
    install_callback(pid, callback)
    signal = Signals.Propose.new!(%{count: "7", observer: self()})

    assert {:ok, state} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
    assert state.counter.count == 7
    assert state.counter.callback == callback
  end

  test "successful native adoption preserves embedded types, multiple mounts and runtime closures",
       context do
    callback = fn value -> value + 1 end
    pid = start_server(context, Agent)
    install_callback(pid, callback)
    signal = Signals.Propose.new!(%{count: 7, observer: self()})

    assert {:ok, state} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
    assert state.state.attempts == 1
    assert %Aikido.StateAdoptionTest.Counter{count: 7, callback: ^callback} = state.counter
    assert %Aikido.StateAdoptionTest.Counter{count: 7} = state.other_counter
    assert_receive {:signal, %Aikido.Signal{type: "state.adopted"}}
  end

  test "native update notifications stay collected until the validated state is adopted",
       context do
    pid = start_server(context, Agent)

    {:ok, subscription} =
      Aikido.AgentServer.subscribe(
        pid,
        "state.propose",
        fn _runtime, event ->
          {:ok, event.directives}
        end,
        once: true
      )

    signal = Signals.Propose.new!(%{count: 7, observer: self(), gate?: true})
    task = Task.async(fn -> Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state}) end)

    on_exit(fn -> send(pid, :adopt_state) end)
    assert_receive {:state_staged, ^pid}
    refute_received {:state_notification, _, _}
    refute_received {:slice_notification, _}
    refute_received {:signal, %Aikido.Signal{type: "state.adopted"}}
    send(pid, :adopt_state)

    assert {:ok, state} = Task.await(task)
    assert state.counter.count == 7
    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, directives}}}

    assert Enum.any?(directives, fn
             %Aikido.Directives.Notify{
               notification: %{
                 resource: Agent,
                 for: [Aikido.StateAdoptionTest.Notifier],
                 data: %{counter: %{count: 7}}
               }
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(directives, fn
             %Aikido.Directives.Notify{
               notification: %{
                 resource: Aikido.StateAdoptionTest.Counter,
                 for: [Aikido.StateAdoptionTest.SliceNotifier],
                 data: %{count: 7}
               }
             } ->
               true

             _ ->
               false
           end)

    refute Enum.any?(directives, fn
             %Aikido.Directives.Notify{notification: %{for: []}} -> true
             _ -> false
           end)

    assert_receive {:state_notification, notifier,
                    %{data: %{counter: %{count: 7}}} = notification}

    refute notifier == pid
    assert notification.action.type == :update
    assert notification.action.name == :__aikido_apply_state__
    assert notification.data.counter.count == 7
    assert_receive {:notification_observed_adopted_count, 7}
    assert_receive {:slice_notification, %{data: %{count: 7}}}
  end

  defp install_callback(pid, callback) do
    signal = Signals.InstallCallback.new!(%{callback: callback})
    assert {:ok, _state} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
  end
end
