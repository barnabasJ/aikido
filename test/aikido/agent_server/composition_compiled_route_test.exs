defmodule R374CompTest.SourceEmit do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    if input.arguments.emit do
      # Synthetic producer: the accepted batch is declared DIRECTLY (the same
      # contract the real Conversation-backed producers satisfy via
      # Conversation.accepted_output/1).
      accepted = [
        ReqLLM.Context.user("r374 accepted one"),
        ReqLLM.Context.user("r374 accepted two")
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

      directive =
        if input.arguments.emit_directive,
          do: [
            Aikido.Directives.emit(%Aikido.Signal{
              id: nil,
              type: "r374.followup",
              source: "/test",
              data: %{}
            })
          ],
          else: []

      Aikido.Types.ActionResult.new(
        changes: Map.take(state, [:log]),
        directives: directive,
        outputs: %{
          accepted_messages: accepted,
          # Output-only canary: lives in the staged fold ONLY, never in any
          # state change — every exposed boundary must hold it absent.
          canary: "r374-staged-only-canary"
        }
      )
    else
      # Stale/no-op transition: nothing appended, nothing staged.
      Aikido.Types.ActionResult.new(changes: %{}, directives: [], outputs: %{})
    end
  end
end

defmodule R374CompTest.FollowerRecord do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @producer_key {{R374CompTest.SourceSlice, :emit}, :src}
  @expected_log ["r374 accepted one", "r374 accepted two"]

  @impl true
  def run(input, _opts, _context) do
    if input.arguments.poison, do: raise("poisoned follower")

    # The fold is namespaced: read the producer's EXACT key — never an
    # enumeration of the whole accumulator.
    accepted =
      input.context.aikido[:staged_outputs]
      |> Map.get(@producer_key, %{})
      |> Map.get(:accepted_messages, [])

    batch =
      Enum.map(accepted, fn message ->
        if is_list(message.content),
          do: Enum.map_join(message.content, "", &(&1.text || "")),
          else: message.content
      end)

    # A non-empty fold proves this action ran AFTER the producer: this
    # action's own context must already carry the producer's ADOPTED state,
    # never an earlier (pre-adoption) context.
    if batch != [] and input.context.aikido.agent.state.src.log != @expected_log do
      raise "follower saw a non-adopted :src state: #{inspect(input.context.aikido.agent.state.src.log)}"
    end

    changes =
      if batch == [],
        do: %{},
        else: %{received: Map.get(input.arguments.state, :received, []) ++ batch}

    Aikido.Types.ActionResult.new(changes: changes, directives: [])
  end
end

defmodule R374CompTest.SourceSlice do
  @moduledoc false
  use Aikido.Slice

  attributes do
    attribute :log, {:array, :term}, default: [], public?: true
  end

  slice do
    name "r374_source"
    route "r374.emit", {__MODULE__, :emit}
  end

  actions do
    action :emit, Aikido.Types.ActionResult do
      argument :state, :term
      argument :emit, :boolean, default: false
      argument :emit_directive, :boolean, default: false
      run R374CompTest.SourceEmit
    end
  end
end

defmodule R374CompTest.MarkFollowup do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context),
    do: Aikido.Types.ActionResult.new(changes: %{followup_ran: true}, directives: [])
end

defmodule R374CompTest.NotificationLog do
  @moduledoc false
  use Agent

  def start_link(_arg), do: Agent.start_link(fn -> {[], :none} end, name: __MODULE__)

  def record(notification),
    do: Agent.cast(__MODULE__, fn {log, awaiter} -> {[notification | log], awaiter} end)

  # Event control: the awaiting test process registers itself BEFORE the emit;
  # the notifier's tagged acknowledgement is then delivered as a message — no
  # polling sleep.
  def register_awaiter do
    me = self()
    Agent.cast(__MODULE__, fn {log, _awaiter} -> {log, me} end)
  end

  # Forward the notifier's tagged acknowledgement to the registered awaiter.
  # Unacknowledged notifications (no awaiter registered yet) are only logged.
  def acknowledge(notification) do
    Agent.cast(__MODULE__, fn
      {log, :none} ->
        {log, :none}

      {log, pid} ->
        send(pid, {:r374_adopted_change, notification})
        {log, :none}
    end)
  end

  def take, do: Agent.get(__MODULE__, fn {log, _awaiter} -> Enum.reverse(log) end)
end

defmodule R374CompTest.ChangeNotifier do
  @moduledoc false
  use Ash.Notifier

  # The acknowledgement TAG is the TESTED ADOPTED CHANGE: the emitted batch the
  # assertions pin on the domain resource. Only a notification whose record
  # carries that batch acknowledges — startup and init notifications (empty
  # `received`) can never acknowledge.
  @tested_adopted_batch "r374 accepted two"

  @impl true
  def notify(notification) do
    R374CompTest.NotificationLog.record(notification)

    case notification.data do
      %{received: received} when is_list(received) ->
        if @tested_adopted_batch in received do
          R374CompTest.NotificationLog.acknowledge(notification)
        end

      _ ->
        :ok
    end
  end
end

defmodule R374CompTest.CompiledAgent do
  @moduledoc false

  # The notifier is a native resource notifier: the notification boundary
  # observes every adopted change, so the canary test can prove no staged
  # output rides a notification.
  use Aikido.Agent, notifiers: [R374CompTest.ChangeNotifier]

  agent do
    name "r374_compiled"
    path :domain

    schema do
      attribute :received, {:array, :term} do
        description "Batches the compiled lower-priority follower received."
        default []
        public? true
      end

      attribute :followup_ran, :boolean do
        description "Whether a delivered r374.followup signal was handled."
        default false
        public? true
      end
    end

    slice :src, R374CompTest.SourceSlice

    # The SAME exact signal type, a LOWER-priority follower: the slice route
    # (-10) produces, this agent route (-20) consumes the namespaced fold.
    route "r374.emit", {__MODULE__, :follow}, priority: -20

    # The emitted followup is DELIVERABLE: this route gives the rollback
    # test's subscription a real, positive control.
    route "r374.followup", {__MODULE__, :mark_followup}, priority: -20
  end

  actions do
    action :follow, Aikido.Types.ActionResult do
      argument :state, :term
      argument :poison, :boolean, default: false
      run R374CompTest.FollowerRecord
    end

    action :mark_followup, Aikido.Types.ActionResult do
      argument :state, :term
      run R374CompTest.MarkFollowup
    end
  end
end

defmodule R374CompTest.CompiledRouteTest do
  @moduledoc """
  Compiled-route and effect checks for the generic staged-output composition.

  Unlike the direct `apply_actions/3` tests, these dispatch through a real
  server's compiled router — the fold must cross a genuine route decision
  (same-exact type, slice producer at -10, agent follower at -20) — and they
  pin the effect boundary: directives returned before a failing follower are
  never executed, the follower reads the producer's exact namespaced key and
  its own context must already carry the producer's adopted state, an
  output-only canary never crosses the diagnostic, checkpoint or notification
  boundaries, and no staged accumulator survives into a later signal.
  """

  use AikidoTest.Case, async: true

  alias Aikido.AgentServer

  @canary "canary"

  defp emit(pid, data, observer) do
    AgentServer.call(pid, signal("r374.emit", data), observer)
  end

  defp state(pid) do
    AgentServer.state(pid, &{:ok, &1.agent.state})
  end

  test "the same-exact route hands the namespaced output to the lower-priority follower", ctx do
    pid = start_server(ctx, R374CompTest.CompiledAgent)

    assert {:ok, agent_state} =
             emit(pid, %{emit: true}, fn runtime -> {:ok, runtime.agent.state} end)

    # The slice producer (priority -10) adopted its own batch.
    assert agent_state.src.log == ["r374 accepted one", "r374 accepted two"]

    # The agent-route follower (priority -20) received that batch through the
    # compiled same-exact route: the namespaced fold crossed the priority
    # boundary, exactly once, in producer order.
    assert agent_state.domain.received == ["r374 accepted one", "r374 accepted two"]
  end

  test "a second signal with no previous output stays silent and carries no residue", ctx do
    pid = start_server(ctx, R374CompTest.CompiledAgent)
    assert {:ok, _} = emit(pid, %{emit: true}, fn runtime -> {:ok, runtime.agent.state} end)

    assert {:ok, agent_state} =
             emit(pid, %{emit: false}, fn runtime -> {:ok, runtime.agent.state} end)

    # The producer staged nothing; the fold carried no first-signal residue,
    # so the follower saw an empty window and stayed silent.
    assert agent_state.domain.received == ["r374 accepted one", "r374 accepted two"]
    assert agent_state.src.log == ["r374 accepted one", "r374 accepted two"]
  end

  test "an observable directive before a failing follower adopts nothing and executes no effect",
       ctx do
    pid = start_server(ctx, R374CompTest.CompiledAgent)

    {:ok, subscription} =
      AgentServer.subscribe(pid, "r374.followup", fn _runtime, _event -> {:ok, :fired} end)

    assert {:error, _error} =
             emit(
               pid,
               %{emit: true, emit_directive: true, poison: true},
               fn runtime -> {:ok, runtime.agent.state} end
             )

    # Neither state was adopted (one transaction, all-or-nothing).
    assert {:ok, %{domain: %{received: [], followup_ran: false}, src: %{log: []}}} = state(pid)

    # The producer's observable directive never executed.
    refute_receive {:aikido_subscription, ^subscription, _}

    # Positive control: the SAME subscription and route DO fire when a turn
    # succeeds — a delivered followup is observed, routed and handled.
    assert {:ok, _} =
             emit(
               pid,
               %{emit: true, emit_directive: true},
               fn runtime -> {:ok, runtime.agent.state} end
             )

    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, :fired}}}

    # The subscription fires after the followup turn adopted its change.
    assert {:ok, %{domain: %{received: received, followup_ran: true}}} = state(pid)
    assert received == ["r374 accepted one", "r374 accepted two"]
  end

  test "the output-only canary never crosses the diagnostic, checkpoint or notification boundaries",
       ctx do
    start_supervised!(R374CompTest.NotificationLog)
    pid = start_server(ctx, R374CompTest.CompiledAgent)

    # Registered BEFORE the emit: the acknowledgement is event-controlled and
    # TAGGED to the tested adopted change — an init notification can never
    # acknowledge it.
    R374CompTest.NotificationLog.register_awaiter()

    assert {:ok, _} = emit(pid, %{emit: true}, fn runtime -> {:ok, runtime.agent.state} end)

    # Diagnostic boundaries: the observed snapshot and the raw server state.
    {:ok, agent_state} = state(pid)
    refute inspect(agent_state) =~ @canary
    refute inspect(:sys.get_state(pid)) =~ @canary

    # Checkpoint boundary: the durable dump holds no staged residue.
    wrapper = :sys.get_state(pid).user_state
    refute inspect(Aikido.Durable.AgentServer.dump_state(wrapper)) =~ @canary

    # Notification boundary: the notifier acknowledges the notification that
    # carries the TESTED ADOPTED CHANGE (the emitted batch on `received`), and
    # that sampled notification carried no staged output.
    assert {:r374_adopted_change, notification} = adopted_change_ack()
    assert notification.data.received == ["r374 accepted one", "r374 accepted two"]
    refute inspect(notification) =~ @canary

    notifications = R374CompTest.NotificationLog.take()
    assert notifications != []
    refute Enum.any?(notifications, &(inspect(&1) =~ @canary))
  end

  # Bounded event wait: the message is sent by the notifier's tagged
  # acknowledgement; the timeout only guards against a lost notification.
  defp adopted_change_ack(timeout \\ 2_000) do
    receive do
      {:r374_adopted_change, notification} -> {:r374_adopted_change, notification}
    after
      timeout -> flunk("no notifier acknowledgement tagged to the adopted change")
    end
  end
end
