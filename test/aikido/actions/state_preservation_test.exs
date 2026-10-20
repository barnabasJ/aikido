defmodule AikidoTest.Actions.StatePreservationTest.State do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :count, :integer do
      description "Current counter value updated by routed signals."
      public? true
      default 42
    end

    attribute :status, :atom do
      description "State status retained by effect-only reducers."
      public? true
      constraints one_of: [:running, :failed]
    end

    attribute :error, :term do
      description "Failure detail retained by effect-only reducers."
      public? true
    end

    attribute :revision, :integer do
      description "Revision whose update default must not run inside a reducer."
      public? true
      update_default &__MODULE__.update_revision/0
    end
  end

  def update_revision do
    raise "update defaults must not run inside a pure reducer"
  end
end

defmodule AikidoTest.Actions.StatePreservationTest.RestrictedState do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :status, :atom do
      description "State status retained by effect-only reducers."
      public? true
      constraints one_of: [:running]
    end

    attribute :error, :term do
      description "Failure detail retained by effect-only reducers."
      public? true
    end
  end
end

defmodule AikidoTest.Actions.StatePreservationTest.Agent do
  use Aikido.Agent

  agent do
    name "effect_state_preservation"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 42
      end
    end

    route "test.noop", {Aikido.AgentServer.RuntimeActions, :noop}
    route "test.broadcast", {Aikido.AgentServer.RuntimeActions, :broadcast}
  end
end

defmodule AikidoTest.Actions.StatePreservationTest do
  use AikidoTest.Case, async: true

  test "effect-only native reducers preserve map and resource state exactly" do
    parent = %Aikido.AgentServer.ParentRef{pid: self(), id: "parent", tag: :child}
    signal = Aikido.Signal.new!("test", %{reply_to: self()})

    actions = [
      noop: %{},
      forward: %{target_pid: self()},
      broadcast: %{pubsub: MyApp.PubSub, topic: "test", signal_type: "test.output"},
      reply: %{signal_type: "test.output"},
      notify_parent: %{signal_type: "test.output"},
      notify_pid: %{target_pid: self(), signal_type: "test.output"},
      spawn_child: %{agent_module: AikidoTest.TestAgents.Minimal, tag: :worker},
      stop_self: %{},
      stop_child: %{tag: :worker},
      schedule_signal: %{delay_ms: 1, signal_type: "test.output"},
      schedule_timeout: %{timeout_ms: 1},
      schedule_cron: %{cron: "* * * * *", signal_type: "test.output"},
      cancel_cron: %{job_id: :tick}
    ]

    for state <- [%{count: 42, other: "keep"}, %__MODULE__.State{count: 42, revision: 7}],
        {action, params} <- actions do
      assert {:ok, result} =
               run_action(action, Map.put(params, :state, state), %{
                 signal: signal,
                 parent: parent
               })

      assert result.state === state, "#{action} changed supplied state"
    end
  end

  test "noop routed through the AgentServer preserves initialized state", context do
    pid = start_server(context, __MODULE__.Agent)

    assert {:ok, %{count: 42}} =
             Aikido.AgentServer.call(pid, signal("test.noop"), &{:ok, &1.agent.state.state})
  end

  test "native routed broadcast delivers a materialized event and preserves state", context do
    pubsub = Module.concat(context.aikido, PubSub)
    start_supervised!({Phoenix.PubSub, name: pubsub})
    topic = "work.available"
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)
    pid = start_server(context, __MODULE__.Agent)
    assert {:ok, before} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})

    assert {:ok, after_broadcast} =
             Aikido.AgentServer.call(
               pid,
               signal("test.broadcast", %{
                 pubsub: pubsub,
                 topic: topic,
                 signal_type: "work.available",
                 payload: %{job: "one"},
                 source: "/test-broadcast"
               }),
               &{:ok, &1.agent.state}
             )

    assert after_broadcast === before

    assert_receive %Aikido.Signal{
                     id: id,
                     time: time,
                     type: "work.available",
                     data: %{job: "one"},
                     source: "/test-broadcast"
                   },
                   2_000

    assert is_binary(id) and id != ""
    assert {:ok, _, _} = DateTime.from_iso8601(time)
  end

  test "cancel keeps unrelated state and validates native resource fields without update defaults" do
    assert {:ok, result} = run_action(:cancel, %{state: %{count: 42}, reason: :requested})
    assert result.state == %{count: 42, status: :failed, error: {:cancelled, :requested}}

    state = %__MODULE__.State{count: 42, status: :running, revision: 7}
    assert {:ok, result} = run_action(:cancel, %{state: state, reason: :requested})
    assert result.state == %{state | status: :failed, error: {:cancelled, :requested}}

    assert {:error, _} = run_action(:cancel, %{state: %Aikido.Slices.Memory{}})

    assert {:error, _} =
             run_action(:cancel, %{state: %__MODULE__.RestrictedState{status: :running}})
  end

  defp run_action(action, params, runtime \\ %{}) do
    Aikido.AgentServer.RuntimeActions
    |> Ash.ActionInput.for_action(action, params, context: %{aikido: runtime})
    |> Ash.run_action()
  end
end
