defmodule Aikido.TodoTest.Agent do
  use Aikido.Agent

  agent do
    name "todo_test"
    slice :ai, Aikido.Slices.AiReact
    slice :todos, Aikido.Slices.Todo
  end
end

defmodule Aikido.TodoTest.Client do
  def generate_text(_, _, _),
    do:
      {:ok,
       struct!(ReqLLM.Response,
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant("finished", tool_calls: []),
         finish_reason: :stop
       )}
end

defmodule Aikido.TodoTest do
  use AikidoTest.Case, async: false

  defp command(pid, type, data) do
    Aikido.AgentServer.call(pid, Jido.Signal.new!(type, data), &{:ok, &1.agent.state})
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

    assert [%Aikido.Slices.Todo.Item{status: :pending, metadata: %{workflow_step_id: "external"}}] =
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

  test "optional todo completion holds an answer and releases it when work is complete", ctx do
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
    {:ok, _} = command(pid, "aikido.todo.complete", %{id: "one", result: "proof"})
    assert {:ok, "finished"} = Task.await(task)
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
    restored = Aikido.Slices.Todo.reinstate(state.todos)
    assert Enum.find(restored.items, &(&1.id == "two")).reason == :interrupted
  end
end
