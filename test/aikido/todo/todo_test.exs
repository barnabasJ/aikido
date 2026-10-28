defmodule Aikido.TodoTest.Agent do
  use Aikido.Agent

  agent do
    name "todo_test"
    slice :ai, Aikido.AiReact.Slice
    slice :todos, Aikido.Todo.Slice
  end
end

defmodule Aikido.TodoTest.Client do
  def generate_text(_, _, _),
    do:
      {:ok,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("finished", tool_calls: []),
         finish_reason: :stop
       }}
end

defmodule Aikido.TodoTest do
  use AikidoTest.Case, async: false

  defp command(pid, type, data) do
    Aikido.AgentServer.call(pid, Aikido.Signal.new!(type, data), &{:ok, &1.agent.state})
  end

  test "typed todos retain application metadata, reject duplicates, and complete idempotently",
       ctx do
    pid = start_server(ctx, Aikido.TodoTest.Agent)

    assert {:ok, state} =
             command(pid, "aikido.todo.add", %{
               id: "one",
               text: "verify",
               metadata: %{workflow_step_id: "external"}
             })

    assert [%Aikido.Todo.Item{status: :pending, metadata: %{workflow_step_id: "external"}}] =
             state.todos.items

    assert {:error, _} = command(pid, "aikido.todo.add", %{id: "one", text: "duplicate"})
    assert {:ok, _} = command(pid, "aikido.todo.activate", %{id: "one"})

    assert {:ok, state} =
             command(pid, "aikido.todo.complete", %{id: "one", result: %{evidence: "verified"}})

    assert [item] = state.todos.items
    assert item.status == :completed

    assert {:ok, repeated} =
             command(pid, "aikido.todo.complete", %{id: "one", result: "replacement"})

    assert repeated.todos.items == state.todos.items
  end

  for action <- ["complete", "remove", "block"] do
    test "todo #{action} settles a waiting run with direct internal delivery", ctx do
      pid = start_server(ctx, Aikido.TodoTest.Agent)
      {:ok, _} = command(pid, "aikido.todo.add", %{id: "one", text: "verify"})

      {:ok, waiting} =
        Aikido.AgentServer.subscribe(
          pid,
          "ai.react.**",
          fn runtime ->
            if runtime.agent.state.ai.status == :waiting, do: {:ok, :waiting}, else: :skip
          end,
          once: true
        )

      opts = [
        model: "offline",
        client: Aikido.TodoTest.Client,
        options: %{completion: :todos},
        timeout: 5_000
      ]

      task = Task.async(fn -> Aikido.AI.ask_sync(pid, "do work", opts) end)
      assert_receive {:aikido_subscription, ^waiting, %{result: {:ok, :waiting}}}, 2_000

      {:ok, _} =
        command(pid, "aikido.todo.#{unquote(action)}", %{
          id: "one",
          result: "proof",
          reason: :blocked
        })

      if unquote(action) == "block" do
        assert {:error, {:todo_blocked, "one", :blocked}} = Task.await(task)
      else
        assert {:ok, "finished"} = Task.await(task)
      end

      refute_received {:signal, %{type: "aikido.todo.changed"}}
    end
  end

  test "obsolete expiry preserves removed and reused IDs while current expiry still blocks" do
    run = fn action, state, data ->
      Aikido.Todo.Slice
      |> Ash.ActionInput.for_action(action, Map.put(data, :state, state),
        context: %{aikido: %{agent_pid: self()}}
      )
      |> Ash.run_action!()
    end

    initial = Ash.create!(Aikido.Todo.Slice, %{}, action: :create)
    added = run.(:todo_add, initial, %{id: "same", text: "original", timeout_ms: 100})
    [original] = added.changes.items
    assert length(added.directives) == 2
    added_state = Ash.update!(initial, added.changes, action: :update)
    removed_result = run.(:todo_remove, added_state, %{id: "same"})
    removed = Ash.update!(added_state, removed_result.changes, action: :update)
    stale = %{id: "same", revision: original.revision}

    assert %Aikido.Types.ActionResult{changes: nil, directives: []} =
             unchanged = run.(:expire, removed, stale)

    assert removed.items == []
    assert run.(:expire, removed, stale) == unchanged

    reused_result = run.(:todo_add, removed, %{id: "same", text: "replacement"})
    reused = Ash.update!(removed, reused_result.changes, action: :update)
    [replacement] = reused.items
    assert replacement.revision > original.revision

    assert %Aikido.Types.ActionResult{changes: nil, directives: []} =
             run.(:expire, reused, stale)

    assert reused.items == [replacement]

    expired = run.(:expire, reused, %{id: "same", revision: replacement.revision})
    assert [%{status: :blocked, reason: :timeout}] = expired.changes.items
    assert length(expired.directives) == 1
    assert initial.items == []
    assert added_state.items == [original]
    assert reused.items == [replacement]

    for action <- [:todo_activate, :todo_complete, :todo_block, :todo_remove] do
      input =
        Ash.ActionInput.for_action(
          Aikido.Todo.Slice,
          action,
          %{state: removed, id: "same", reason: :unknown},
          skip_unknown_inputs: [:*]
        )

      assert {:error, %Ash.Error.Unknown{}} = Ash.run_action(input)
    end
  end

  test "a todo deadline fails a waiting run and codecs never leave a lost timer active", ctx do
    pid = start_server(ctx, Aikido.TodoTest.Agent)
    {:ok, _} = command(pid, "aikido.todo.add", %{id: "one", text: "wait", timeout_ms: 100})

    opts = [
      model: "offline",
      client: Aikido.TodoTest.Client,
      options: %{completion: :todos},
      timeout: 5_000
    ]

    assert {:error, {:todo_blocked, "one", :timeout}} = Aikido.AI.ask_sync(pid, "wait", opts)
    {:ok, state} = command(pid, "aikido.todo.add", %{id: "two", text: "wait", timeout_ms: 1_000})
    restored = Aikido.Todo.Slice.reinstate(state.todos)
    assert Enum.find(restored.items, &(&1.id == "two")).reason == :interrupted
  end
end
