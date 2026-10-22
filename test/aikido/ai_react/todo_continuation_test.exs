defmodule Aikido.TodoContinuationTest.Agent do
  use Aikido.Agent

  agent do
    name "todo_continuation"
    slice :ai, Aikido.AiReact.Slice
    slice :todos, Aikido.Todo.Slice
  end
end

defmodule Aikido.TodoContinuationTest.Verify do
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, context) do
    send(
      input.arguments.metadata.observer,
      {:verifier, self(), input.arguments.answer, context.actor, context.tenant}
    )

    receive do
      {:verdict, verdict} -> {:ok, verdict}
    end
  end
end

defmodule Aikido.TodoContinuationTest.Verifier do
  use Ash.Resource, domain: Aikido.RuntimeDomain

  actions do
    action :verify, :boolean do
      argument :answer, :term
      argument :todos, {:array, :term}
      argument :metadata, :map
      run Aikido.TodoContinuationTest.Verify
    end
  end
end

defmodule Aikido.TodoContinuationTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model, self(), messages})

    receive do
      {:answer, response} -> response
    end
  end
end

defmodule Aikido.TodoContinuationTest do
  use AikidoTest.Case, async: true
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  defp options(observer, extra \\ %{}) do
    [
      model: "offline",
      client: Aikido.TodoContinuationTest.Client,
      llm_opts: [observer: observer],
      metadata: %{observer: observer},
      actor: %{id: "worker"},
      tenant: "org",
      options:
        Map.merge(
          %{completion: :todos, todo_continuation: :continue, max_todo_continuations: 1},
          extra
        )
    ]
  end

  defp add_todo(pid) do
    signal = Aikido.Todo.Signals.TodoAdd.new!(%{id: "work", text: "provide proof"})
    Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :added} end)
  end

  test "open work requests bounded additional model turns instead of waiting forever", ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)
    opts = options(self())
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("not done")}})
    assert_receive {:model, next, messages}, 5_000
    assert Enum.map_join(List.last(messages).content, &(&1.text || "")) =~ "provide proof"
    send(next, {:answer, {:ok, Responses.final_answer_response("still not done")}})
    assert {:error, {:todo_continuation_limit, 1}} = Task.await(task)
  end

  test "native verifier runs under the caller scope and rejects before accepting another answer",
       ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)
    opts = options(self(), %{todo_verifier: {Aikido.TodoContinuationTest.Verifier, :verify}})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "verify", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("first")}})
    assert_receive {:verifier, verify, "first", %{id: "worker"}, "org"}, 5_000
    refute_received {:model, _, _}
    send(verify, {:verdict, false})
    assert_receive {:model, next, _}, 5_000
    send(next, {:answer, {:ok, Responses.final_answer_response("evidence")}})
    assert_receive {:verifier, verify, "evidence", %{id: "worker"}, "org"}, 5_000
    send(verify, {:verdict, true})
    assert {:ok, "evidence"} = Task.await(task)
  end

  test "waiting verification is rerun after external todo evidence and cancels with its run",
       ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)

    opts =
      options(self(), %{
        todo_continuation: :wait,
        todo_verifier: {Aikido.TodoContinuationTest.Verifier, :verify}
      })

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "verify", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("proposed")}})
    assert_receive {:verifier, verifier, "proposed", %{id: "worker"}, "org"}, 5_000
    send(verifier, {:verdict, false})

    assert :waiting =
             AikidoTest.AgentWait.await_state_value(pid, fn runtime ->
               if runtime.agent.state.ai.status == :waiting, do: :waiting
             end)

    signal = Aikido.Todo.Signals.TodoComplete.new!(%{id: "work", result: "external evidence"})
    assert {:ok, :added} = Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :added} end)
    assert_receive {:verifier, verifier, "proposed", %{id: "worker"}, "org"}, 5_000
    monitor = Process.monitor(verifier)
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^verifier, _}, 5_000
  end

  test "evidence changes invalidate a verifier's old verdict", ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)
    opts = options(self(), %{todo_verifier: {Aikido.TodoContinuationTest.Verifier, :verify}})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "verify", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("proposal")}})
    assert_receive {:verifier, first, "proposal", _, _}, 5_000
    signal = Aikido.Todo.Signals.TodoAdd.new!(%{id: "later", text: "new evidence required"})
    assert {:ok, :added} = Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :added} end)
    send(first, {:verdict, true})
    assert_receive {:verifier, second, "proposal", _, _}, 5_000
    assert Task.yield(task, 0) == nil
    send(second, {:verdict, true})
    assert {:ok, "proposal"} = Task.await(task)
  end

  test "atomic task delivery retains the ordinary todo deadline", ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    opts = options(self(), %{todo_continuation: :wait})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "start", opts) end)
    assert_receive {:model, _, _}, 5_000

    signal =
      Aikido.AiReact.Signals.Deliver.new!(%{
        text: "deadline",
        request_id: "delivery",
        todo: %{id: "deadline", text: "expiring", timeout_ms: 10}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "worker"}, tenant: "org"})

    assert {:ok, :blocked} =
             Aikido.AgentServer.call_until(pid, signal, "aikido.todo.**", fn runtime ->
               if Enum.any?(
                    runtime.agent.state.todos.items,
                    &(&1.id == "deadline" && &1.status == :blocked)
                  ), do: {:ok, :blocked}, else: :skip
             end)

    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
  end

  test "incoming task delivery adds its todo and text in the same state transition", ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    opts = options(self(), %{todo_continuation: :wait})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "start", opts) end)
    assert_receive {:model, model, _}, 5_000

    signal =
      Aikido.AiReact.Signals.Deliver.new!(%{
        text: "new work",
        request_id: "delivery",
        todo: %{id: "work", text: "new work"}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "worker"}, tenant: "org"})

    assert {:ok, {["new work"], ["work"]}} =
             Aikido.AgentServer.call(pid, signal, fn runtime ->
               {:ok,
                {runtime.agent.state.ai.queued_messages,
                 Enum.map(runtime.agent.state.todos.items, & &1.id)}}
             end)

    assert {:error, _} = Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :unexpected} end)
    monitor = Process.monitor(model)
    assert :ok = Aikido.AI.cancel(pid)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000
  end
end
