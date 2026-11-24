defmodule Aikido.ExplicitMountTest.Accept do
  use Aikido.Signal

  signal do
    type "mount.accept"

    schema do
      attribute :fresh, :boolean do
        description "Whether this transition accepts a new message."
        default true
      end

      attribute :fail, :boolean do
        description "Reject after the Thread follower stages its update."
        default false
      end

      attribute :invalid, :boolean do
        description "Return invalid Thread attributes to exercise native adoption validation."
        default false
      end
    end
  end
end

defmodule Aikido.ExplicitMountTest.Produce do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    if input.arguments.fresh do
      Aikido.Types.ActionResult.new(
        changes: %{accepted: input.arguments.state.accepted + 1},
        outputs: %{accepted_messages: [ReqLLM.Context.user("accepted message")]},
        directives: [
          Aikido.Directives.emit(%Aikido.Signal{type: "mount.effect", data: %{}})
        ]
      )
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end

defmodule Aikido.ExplicitMountTest.Source do
  use Aikido.Slice

  slice do
    name "mount_source"

    schema do
      attribute :accepted, :integer do
        description "Number of accepted source transitions."
        default 0
        allow_nil? false
      end
    end

    route Aikido.ExplicitMountTest.Accept, Aikido.ExplicitMountTest.Produce,
      name: :produce,
      public?: false
  end
end

defmodule Aikido.ExplicitMountTest.Record do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    context = input.context.aikido
    thread = input.arguments.state
    true = is_struct(thread, Aikido.Thread.Slice)

    messages =
      context.staged_outputs
      |> Map.get({{Aikido.ExplicitMountTest.Source, :produce}, :src}, %{})
      |> Map.get(:accepted_messages, [])

    if messages != [], do: true = context.agent.state.src.accepted > 0

    entries =
      Enum.with_index(messages, fn message, index ->
        %{id: "#{context.signal.id}:#{index}", kind: :message, payload: %{role: message.role}}
      end)

    append(thread, entries, input.arguments.invalid, context)
  end

  defp append(_thread, [], false, _context),
    do: Aikido.Types.ActionResult.new(changes: nil)

  defp append(thread, entries, invalid, context) do
    with {:ok, updated} <- Aikido.Thread.Journal.append(thread, entries, context.signal) do
      {updated, directives} = Aikido.Thread.Followers.offer_all(updated, context, :thread)
      changes = Aikido.Thread.Journal.changes(thread, updated)

      changes =
        if invalid, do: Map.put(changes, :entries, :invalid), else: changes

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end
end

defmodule Aikido.ExplicitMountTest.Reject do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    if input.arguments.fail,
      do: {:error, "downstream rejected"},
      else: Aikido.Types.ActionResult.new(changes: nil)
  end
end

defmodule Aikido.ExplicitMountTest.MarkEffect do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context),
    do: Aikido.Types.ActionResult.new(changes: %{effects: input.arguments.state.effects + 1})
end

defmodule Aikido.ExplicitMountTest.Agent do
  use Aikido.Agent

  agent do
    name "explicit_mount"
    path :domain

    schema do
      attribute :effects, :integer do
        description "Effects observed after a successful transition."
        default 0
      end
    end

    slice :src, Aikido.ExplicitMountTest.Source
    slice :thread, Aikido.Thread.Slice
    slice :other_thread, Aikido.Thread.Slice

    route Aikido.ExplicitMountTest.Accept, Aikido.ExplicitMountTest.Record,
      mount: :thread,
      name: :record,
      public?: false,
      priority: -20

    route Aikido.ExplicitMountTest.Accept, Aikido.ExplicitMountTest.Reject,
      name: :reject,
      public?: false,
      priority: -30

    route "mount.effect", Aikido.ExplicitMountTest.MarkEffect, public?: false
  end
end

defmodule Aikido.ExplicitMountTest.RecordModelMessages do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    context = input.context.aikido

    accepted =
      context.staged_outputs
      |> Map.get({{Aikido.AiReact.Slice, :llm_turn}, :ai}, %{})
      |> Map.get(:accepted_messages, [])

    if accepted == [] do
      Aikido.Types.ActionResult.new(changes: nil)
    else
      true = Enum.all?(accepted, &(&1 in context.agent.state.ai.context.messages))

      entries =
        Enum.with_index(accepted, fn message, index ->
          %{id: "#{context.signal.id}:#{index}", kind: :message, payload: %{role: message.role}}
        end)

      with {:ok, updated} <-
             Aikido.Thread.Journal.append(input.arguments.state, entries, context.signal) do
        {updated, directives} = Aikido.Thread.Followers.offer_all(updated, context, :thread)

        Aikido.Types.ActionResult.new(
          changes: Aikido.Thread.Journal.changes(input.arguments.state, updated),
          directives: directives
        )
      end
    end
  end
end

defmodule Aikido.ExplicitMountTest.ModelAgent do
  use Aikido.Agent

  agent do
    name "model_thread_mount"
    slice :ai, Aikido.AiReact.Slice
    slice :thread, Aikido.Thread.Slice

    route Aikido.AiReact.Signals.LlmTurn, Aikido.ExplicitMountTest.RecordModelMessages,
      mount: :thread,
      name: :record_model_messages,
      public?: false,
      priority: -20
  end
end

defmodule Aikido.ExplicitMountTest.NativeThreadAgent do
  use Aikido.Agent

  agent do
    name "native_thread_alias"
    slice :thread, Aikido.Thread.Slice

    route Aikido.Thread.Signals.Append, {Aikido.Thread.Slice, :append}, name: :append_entry
  end
end

defmodule Aikido.ExplicitRouteMountTest do
  use AikidoTest.Case, async: true
  alias Aikido.AgentServer
  alias Aikido.ExplicitMountTest, as: Fixtures

  defp accept(pid, data),
    do: AgentServer.call(pid, signal("mount.accept", data), &{:ok, &1.agent.state})

  defp state(pid), do: AgentServer.state(pid, &{:ok, &1.agent.state})

  test "one native Thread mount and its public alias invoke append exactly once", ctx do
    pid = start_server(ctx, Fixtures.NativeThreadAgent)
    assert Ash.Resource.Info.action(Fixtures.NativeThreadAgent, :append_entry)

    event = signal("aikido.thread.append", %{entry: %{kind: :note, payload: %{text: "once"}}})
    assert {:ok, result} = AgentServer.call(pid, event, &{:ok, &1.agent.state})

    # Ordinary Thread appends have no replay de-duplication: two reducer
    # invocations would append two entries and advance the revision twice.
    assert result.thread.replay? == false
    assert result.thread.rev == 1
    assert [entry] = result.thread.entries
    assert entry.payload == %{text: "once"}
  end

  test "real ReAct completion is adopted by Thread in the same compiled transition", ctx do
    pid =
      start_server(ctx, Fixtures.ModelAgent,
        initial_state: %{
          ai: %{
            status: :running,
            request_id: "model-run",
            model: "offline",
            context: ReqLLM.Context.new([ReqLLM.Context.user("question")])
          }
        }
      )

    response = %ReqLLM.Response{
      id: "model-response",
      model: "offline",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant("answer"),
      finish_reason: :stop
    }

    event = signal("ai.react.llm.completed", %{request_id: "model-run", turn: response})
    assert {:ok, first} = AgentServer.call(pid, event, &{:ok, &1.agent.state})
    assert first.ai.status == :completed
    assert [entry] = first.thread.entries
    assert entry.payload == %{role: :assistant}
    assert List.last(first.ai.context.messages) == response.message

    assert {:ok, replayed} = AgentServer.call(pid, event, &{:ok, &1.agent.state})
    assert replayed.thread == first.thread
  end

  test "compiled follower adopts native Thread only, after source acceptance", ctx do
    pid = start_server(ctx, Fixtures.Agent)
    assert {:ok, result} = accept(pid, %{})
    assert result.src.accepted == 1
    assert %Aikido.Thread.Slice{entries: [entry]} = result.thread
    assert entry.payload == %{role: :user}
    assert result.other_thread.entries == []
    assert Map.keys(result.domain) == [:effects]

    paths = Aikido.Agent.Info.slice_paths_for_action(Fixtures.Agent)
    assert paths[{Fixtures.Agent, :record}] == [:thread]
    assert Enum.sort(paths[{Aikido.Thread.Slice, :append}]) == [:other_thread, :thread]

    definition = Ash.Resource.Info.action(Fixtures.Agent, :record)
    argument = Enum.find(definition.arguments, &(&1.name == :state))
    assert argument.type == Ash.Type.Struct
    assert argument.constraints[:instance_of] == Aikido.Thread.Slice
  end

  test "normal Thread routes remain installed and executable", ctx do
    pid = start_server(ctx, Fixtures.Agent)
    assert {:ok, first} = accept(pid, %{})
    assert length(first.thread.entries) == 1

    assert {:ok, result} =
             AgentServer.call(pid, signal("aikido.thread.clear"), &{:ok, &1.agent.state})

    assert result.thread.entries == []
    assert result.thread.rev == first.thread.rev + 1
    assert result.other_thread.entries == []
    assert result.src.accepted == 1
  end

  test "a later no-op carries no accepted messages from the previous signal", ctx do
    pid = start_server(ctx, Fixtures.Agent)
    assert {:ok, first} = accept(pid, %{})
    assert {:ok, second} = accept(pid, %{fresh: false})
    assert second.thread == first.thread
    assert second.src == first.src
    assert second.other_thread.entries == []
  end

  test "downstream failure rolls back source and Thread and suppresses effects", ctx do
    pid = start_server(ctx, Fixtures.Agent)
    {:ok, sub} = AgentServer.subscribe(pid, "mount.effect", fn _, _ -> {:ok, :seen} end)
    assert {:error, _} = accept(pid, %{fail: true})
    assert {:ok, result} = state(pid)
    assert result.src.accepted == 0
    assert result.thread.entries == []
    assert result.other_thread.entries == []
    assert result.domain.effects == 0
    refute_receive {:aikido_subscription, ^sub, _}

    assert {:ok, _} = accept(pid, %{})
    assert_receive {:aikido_subscription, ^sub, _}
    assert {:ok, result} = state(pid)
    assert result.domain.effects == 1
  end

  test "native mounted resource rejects invalid changes atomically", ctx do
    pid = start_server(ctx, Fixtures.Agent)
    assert {:error, _} = accept(pid, %{invalid: true})
    assert {:ok, result} = state(pid)
    assert result.src.accepted == 0
    assert result.thread.entries == []
    assert result.domain.effects == 0
  end
end
