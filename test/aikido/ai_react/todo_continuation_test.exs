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

defmodule Aikido.TodoContinuationTest.DeliveryGate do
  @moduledoc false

  @spec wait(request :: map(), context :: map()) :: {:ok, map()} | {:error, :fixture_timeout}
  def wait(_request, %{event: %{metadata: %{observer: observer}}} = context) do
    send(observer, {:delivery_gate, self(), context})

    receive do
      {:release, decision} -> {:ok, decision}
    after
      10_000 -> {:error, :fixture_timeout}
    end
  end
end

defmodule Aikido.TodoContinuationTest.DeliveryClient do
  @moduledoc false
  @behaviour Aikido.AiReact.Client

  @impl Aikido.AiReact.Client
  @spec generate_text(model :: term(), messages :: list(), opts :: keyword()) :: term()
  def generate_text(_model, messages, opts) do
    send(opts[:observer], {:delivery_model, self(), messages, opts[:tools]})

    receive do
      {:answer, response} -> response
    after
      10_000 -> {:error, :fixture_timeout}
    end
  end
end

defmodule Aikido.TodoContinuationTest do
  use AikidoTest.Case, async: true

  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  for mode <- [:wait, :continue] do
    test "executable tool exhaustion fails with open Todos in #{mode} mode", ctx do
      pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
      assert {:ok, :added} = add_todo(pid)
      assert {:ok, before} = delivery_state(pid)

      opts =
        options(self(), %{todo_continuation: unquote(mode), handoff: false})
        |> Keyword.put(:max_iterations, 1)
        |> Keyword.put(:tools, [:test_add])

      {:ok, subscription} =
        Aikido.AgentServer.subscribe(
          pid,
          "ai.react.llm.completed",
          fn runtime, event ->
            {:ok, %{ai: runtime.agent.state.ai, directives: event.directives}}
          end,
          once: true
        )

      task = Task.async(fn -> Aikido.AI.ask_sync(pid, "provide proof", opts) end)
      assert_receive {:model, model, _}, 5_000
      calls = [ReqLLM.ToolCall.new("todo-limit", "test_add", ~s({"a":1,"b":2}))]

      response = %ReqLLM.Response{
        id: "todo-limit",
        model: "offline",
        context: ReqLLM.Context.new(),
        usage: %{input_tokens: 11, output_tokens: 7},
        message: ReqLLM.Context.assistant("unfinished", tool_calls: calls),
        finish_reason: :tool_calls
      }

      send(model, {:answer, {:ok, response}})
      assert {:error, :max_iterations} = Task.await(task, 5_000)
      assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, observed}}}, 5_000
      refute Enum.any?(observed.directives, &match?(%Aikido.AiReact.Directives.ToolExec{}, &1))
      assert observed.ai.status == :failed
      assert observed.ai.error == :max_iterations
      assert observed.ai.result == nil
      assert observed.ai.iteration == 1
      assert observed.ai.pending_tool_calls == []
      assert observed.ai.usage.input_tokens == 11
      assert observed.ai.usage.output_tokens == 7
      assert List.last(observed.ai.context.messages) == response.message
      assert {:ok, after_run} = delivery_state(pid)
      assert after_run.todos == before.todos
      refute_received {:model, _, _}
    end
  end

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

  test "verification cannot outlive the run's remaining deadline", ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)

    opts =
      options(self(), %{
        model_timeout_ms: 30_000,
        todo_verifier: {Aikido.TodoContinuationTest.Verifier, :verify}
      })
      |> Keyword.put(:metadata, %{
        observer: self(),
        aikido_deadline_at: System.system_time(:millisecond) + 1_000
      })

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "verify within budget", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("proposal")}})
    assert_receive {:verifier, verifier, "proposal", _, _}, 5_000
    monitor = Process.monitor(verifier)

    assert {:error, :timeout} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^verifier, _}, 5_000
  end

  test "typed text delivery without a todo resumes required work without changing its requirements",
       ctx do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)
    opts = options(self(), %{todo_continuation: :wait})
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "wait for evidence", opts) end)
    assert_receive {:model, model, _}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("waiting")}})

    assert :waiting =
             AikidoTest.AgentWait.await_state_value(pid, fn runtime ->
               if runtime.agent.state.ai.status == :waiting, do: :waiting
             end)

    delivery =
      Aikido.AiReact.Signals.Deliver.new!(%{
        text: "Worker evidence arrived",
        request_id: "task-result/work",
        metadata: %{}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "worker"}, tenant: "org"})

    assert {:ok, [%{id: "work", status: :pending}]} =
             Aikido.AgentServer.call(pid, delivery, &{:ok, &1.agent.state.todos.items})

    assert_receive {:model, next, messages}, 5_000

    assert Enum.any?(messages, fn message ->
             Enum.any?(message.content, &(&1.text == "Worker evidence arrived"))
           end)

    complete = Aikido.Todo.Signals.TodoComplete.new!(%{id: "work", result: "Checked evidence"})

    assert {:ok, :completed} =
             Aikido.AgentServer.call(pid, complete, fn _ -> {:ok, :completed} end)

    send(next, {:answer, {:ok, Responses.final_answer_response("checked")}})
    assert {:ok, "checked"} = Task.await(task)
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

  # Each case starts below the budget. Only the delivery or its hook context can
  # push the resumed request across it; neither initial setup nor a tool does so.
  for {name, delivered, hook_text, handoff?} <- [
        {"normal", "Worker evidence arrived", "approved evidence", false},
        {"delivery budget", String.duplicate("delivery evidence ", 300), "approved evidence",
         true},
        {"hook budget", "Worker evidence arrived", String.duplicate("hook evidence ", 400), true}
      ] do
    test "waiting delivery runs the gate before the #{name} decision", ctx do
      {pid, before} = waiting_delivery(ctx)
      delivered = unquote(delivered)
      hook_text = unquote(hook_text)
      assert {:ok, :accepted} = deliver_waiting(pid, delivered)
      assert_receive {:delivery_gate, gate, context}, 5_000
      assert context.request_id == before.ai.request_id

      assert context.event.metadata.deliveries == [
               %{request_id: "worker-delivery", metadata: %{source: "worker"}}
             ]

      assert {:ok, held} = delivery_state(pid)
      assert_same_waiting_run(before, held)
      assert held.ai.handoff_pending == nil
      assert held.ai.hook_sequence == before.ai.hook_sequence + 1
      refute_received {:delivery_model, _, _, _}
      send(gate, {:release, %{decision: "continue", context: hook_text}})
      assert_receive {:delivery_model, model, messages, tools}, 5_000
      assert {:ok, resumed} = delivery_state(pid)
      assert_same_waiting_run(before, resumed)
      assert resumed.ai.hooks_pending == %{}
      assert resumed.ai.hook_context == []
      assert resumed.ai.queued_messages == []
      assert resumed.ai.hook_sequence == before.ai.hook_sequence + 1
      texts = Enum.map(messages, &delivery_text/1)
      assert Enum.count(texts, &(&1 == String.trim(delivered))) == 1
      hook_message = String.trim("[Hook context: delivery gate]\n" <> hook_text)
      assert Enum.count(texts, &(&1 == hook_message)) == 1

      assert Enum.find_index(texts, &(&1 == String.trim(delivered))) <
               Enum.find_index(texts, &(&1 == hook_message))

      if unquote(handoff?) do
        assert tools == []
        assert resumed.ai.handoff_pending == 1
        assert resumed.ai.handoff_count == 1
        assert delivery_text(List.last(messages)) =~ "ONLY thing your successor receives"
        assert Aikido.AiReact.Conversation.input_token_count(resumed.ai) >= 1_000
      else
        assert [%ReqLLM.Tool{name: "test_add"}] = tools
        assert resumed.ai.handoff_pending == nil
        assert resumed.ai.handoff_count == 0
        assert Aikido.AiReact.Conversation.input_token_count(resumed.ai) < 1_000
        assert delivery_text(List.last(messages)) == hook_message
      end

      monitor = Process.monitor(model)
      assert :ok = Aikido.AI.cancel(pid)
      assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000
      assert :failed = await_delivery_status(pid, :failed).ai.status
      refute_received {:delivery_gate, _, _}
      refute_received {:delivery_model, _, _, _}
    end
  end

  for outcome <- [:deny, :cancel] do
    test "waiting delivery cannot bypass a held gate on #{outcome}", ctx do
      {pid, before} = waiting_delivery(ctx)
      assert {:ok, :accepted} = deliver_waiting(pid, "Worker evidence arrived")
      assert_receive {:delivery_gate, gate, _}, 5_000
      assert {:ok, held} = delivery_state(pid)
      assert_same_waiting_run(before, held)
      assert [token] = Map.keys(held.ai.hooks_pending)
      refute_received {:delivery_model, _, _, _}

      case unquote(outcome) do
        :deny ->
          send(gate, {:release, %{decision: "deny", message: "blocked"}})
          failed = await_delivery_status(pid, :failed)
          assert failed.ai.error == {:hook_denied, "delivery gate", "blocked"}

        :cancel ->
          assert :ok = Aikido.AI.cancel(pid)
          failed = await_delivery_status(pid, :failed)
          assert failed.ai.error == :cancelled
          assert failed.ai.hooks_pending == %{}
          refute_received {:delivery_model, _, _, _}

          # The application owns its callback wait. Complete that real callback
          # after cancellation and observe its actual late result at the server.
          assert {:ok, subscription} =
                   Aikido.AgentServer.subscribe(
                     pid,
                     "ai.react.hook.completed",
                     fn runtime ->
                       {:ok, %{ai: runtime.agent.state.ai, todos: runtime.agent.state.todos}}
                     end,
                     once: true
                   )

          monitor = Process.monitor(gate)
          send(gate, {:release, %{decision: "continue", context: "late callback approval"}})
          assert_receive {:DOWN, ^monitor, :process, ^gate, _}, 5_000
          assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, unchanged}}}, 5_000
          assert unchanged == failed
      end

      late =
        Aikido.AiReact.Signals.HookCompleted.new!(%{
          request_id: before.ai.request_id,
          token: token,
          name: "delivery gate",
          mode: :sync,
          result: {:ok, %Aikido.AiReact.Hooks.Decision{context: "stale approval"}}
        })

      assert {:ok, failed} = delivery_state(pid)
      assert failed.ai.hooks_pending == %{}
      assert failed.todos == before.todos

      assert {:ok, unchanged} =
               Aikido.AgentServer.call(pid, late, fn runtime ->
                 {:ok, %{ai: runtime.agent.state.ai, todos: runtime.agent.state.todos}}
               end)

      assert unchanged == failed
      refute_received {:delivery_model, _, _, _}
    end
  end

  for kind <- [:deliver, :message] do
    test "waiting #{kind} keeps raw feedback through a successful handoff", ctx do
      {pid, before} = waiting_delivery(ctx)
      feedback = "new worker feedback"

      case unquote(kind) do
        :deliver ->
          assert {:ok, :accepted} = deliver_waiting(pid, feedback)

        :message ->
          assert {:ok, :queued} =
                   Aikido.AI.queue_message(pid, feedback, actor: %{id: "worker"}, tenant: "org")
      end

      assert_receive {:delivery_gate, first_gate, _}, 5_000

      send(
        first_gate,
        {:release, %{decision: "continue", context: String.duplicate("pressure ", 400)}}
      )

      assert_receive {:delivery_model, writer, writer_messages, []}, 5_000
      assert Enum.count(writer_messages, &(delivery_text(&1) == feedback)) == 1
      send(writer, {:answer, {:ok, Responses.final_answer_response("Continue the work")}})
      assert_receive {:delivery_gate, second_gate, _}, 5_000
      send(second_gate, {:release, %{decision: "continue"}})

      assert_receive {:delivery_model, successor, messages, [%ReqLLM.Tool{name: "test_add"}]},
                     5_000

      assert Enum.count(messages, &(delivery_text(&1) == feedback)) == 1

      assert Enum.find_index(messages, &(delivery_text(&1) =~ "taking over mid-run")) <
               Enum.find_index(messages, &(delivery_text(&1) == feedback))

      assert {:ok, resumed} = delivery_state(pid)
      assert_same_waiting_run(before, resumed)
      monitor = Process.monitor(successor)
      assert :ok = Aikido.AI.cancel(pid)
      assert_receive {:DOWN, ^monitor, :process, ^successor, _}, 5_000
    end
  end

  test "public queue_message resumes waiting through one scoped gate", ctx do
    {pid, before} = waiting_delivery(ctx)

    assert {:ok, :queued} =
             Aikido.AI.queue_message(pid, "Queued feedback",
               actor: %{id: "worker"},
               tenant: "org"
             )

    assert_receive {:delivery_gate, gate, context}, 5_000
    assert context.request_id == before.ai.request_id
    assert {:ok, held} = delivery_state(pid)
    assert_same_waiting_run(before, held)
    assert held.ai.hook_sequence == before.ai.hook_sequence + 1
    refute_received {:delivery_model, _, _, _}

    send(gate, {:release, %{decision: "continue", context: "queue approval"}})
    assert_receive {:delivery_model, model, messages, [%ReqLLM.Tool{name: "test_add"}]}, 5_000
    assert {:ok, resumed} = delivery_state(pid)
    assert_same_waiting_run(before, resumed)
    assert resumed.ai.hook_sequence == before.ai.hook_sequence + 1
    assert resumed.ai.hooks_pending == %{}
    texts = Enum.map(messages, &delivery_text/1)
    assert Enum.count(texts, &(&1 == "Queued feedback")) == 1
    assert Enum.count(texts, &(&1 == "[Hook context: delivery gate]\nqueue approval")) == 1
    monitor = Process.monitor(model)
    assert :ok = Aikido.AI.cancel(pid)
    assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000
    assert :failed = await_delivery_status(pid, :failed).ai.status
    refute_received {:delivery_gate, _, _}
    refute_received {:delivery_model, _, _, _}
  end

  defp waiting_delivery(ctx) do
    pid = start_server(ctx, Aikido.TodoContinuationTest.Agent)
    assert {:ok, :added} = add_todo(pid)

    assert {:ok, :added} =
             Aikido.AgentServer.call(
               pid,
               Aikido.Todo.Signals.TodoAdd.new!(%{id: "proved", text: "retain earlier evidence"}),
               fn _ -> {:ok, :added} end
             )

    assert {:ok, :completed} =
             Aikido.AgentServer.call(
               pid,
               Aikido.Todo.Signals.TodoComplete.new!(%{id: "proved", result: "retained proof"}),
               fn _ -> {:ok, :completed} end
             )

    observer = self()

    hook = %{
      name: "delivery gate",
      event: :before_model,
      request: &Aikido.TodoContinuationTest.DeliveryGate.wait/2,
      script: """
      local answer = aikido.request("approve.delivery", {})
      return answer
      """
    }

    opts =
      options(observer, %{
        todo_continuation: :wait,
        context_max_tokens: 1_000,
        handoff_buffer_tokens: 0
      })
      |> Keyword.put(:client, Aikido.TodoContinuationTest.DeliveryClient)
      |> Keyword.put(:tools, [:test_add])
      |> Keyword.put(:hooks, [hook])
      |> Keyword.put(:metadata, %{
        observer: observer,
        aikido_deadline_at: System.system_time(:millisecond) + 300_000
      })

    assert {:ok, _} = Aikido.AI.ask(pid, "wait for evidence", opts)
    assert_receive {:delivery_gate, initial_gate, _}, 5_000
    send(initial_gate, {:release, %{decision: "continue"}})
    assert_receive {:delivery_model, model, _, [%ReqLLM.Tool{name: "test_add"}]}, 5_000
    send(model, {:answer, {:ok, Responses.final_answer_response("waiting")}})
    before = await_delivery_status(pid, :waiting)
    assert before.ai.result == "waiting"

    assert %{id: "work", status: :pending, result: nil} =
             Enum.find(before.todos.items, &(&1.id == "work"))

    assert %{id: "proved", status: :completed, result: "retained proof"} =
             Enum.find(before.todos.items, &(&1.id == "proved"))

    assert Aikido.AiReact.Conversation.input_token_count(before.ai) < 1_000
    {pid, before}
  end

  defp deliver_waiting(pid, text) do
    signal =
      Aikido.AiReact.Signals.Deliver.new!(%{
        text: text,
        request_id: "worker-delivery",
        metadata: %{source: "worker"}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "worker"}, tenant: "org"})

    Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :accepted} end)
  end

  defp delivery_state(pid) do
    Aikido.AgentServer.state(pid, fn runtime ->
      {:ok, %{ai: runtime.agent.state.ai, todos: runtime.agent.state.todos}}
    end)
  end

  defp await_delivery_status(pid, status) do
    AikidoTest.AgentWait.await_state_value(
      pid,
      fn runtime ->
        if runtime.agent.state.ai.status == status,
          do: %{ai: runtime.agent.state.ai, todos: runtime.agent.state.todos}
      end,
      timeout: 5_000
    )
  end

  defp assert_same_waiting_run(before, after_delivery) do
    assert after_delivery.ai.request_id == before.ai.request_id
    assert after_delivery.ai.deadline_at == before.ai.deadline_at
    assert after_delivery.ai.run_scope == before.ai.run_scope
    assert after_delivery.ai.prepared_tools == before.ai.prepared_tools
    assert after_delivery.todos == before.todos
    assert after_delivery.ai.result == nil
  end

  defp delivery_text(message), do: Enum.map_join(message.content, &(&1.text || ""))
end
