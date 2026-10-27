defmodule Aikido.AICapacityTest.Observe do
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _opts, next) do
    shared = Map.merge(%{kind: nil}, get_in(context, [:context, :shared]) || %{})

    if signal.type == "ai.react.tools.ready" && shared.kind in [:model, :tool] do
      send(shared.observer, {:tools_prepared, self(), signal.data.request_id})

      receive do
        {:release_prepared, request_id} when request_id == signal.data.request_id -> :ok
      after
        5_000 -> raise "capacity test did not release the prepared-tools gate"
      end
    end

    if is_pid(shared[:observer]) && signal.type in ["ai.react.failed", "ai.react.tool.completed"] do
      send(shared.observer, {:capacity_result, signal.type, signal.data, context})
    end

    case next.(signal, context) do
      {:ok, context, directives}
      when signal.type == "ai.react.tools.ready" and shared.kind == :tool ->
        # Only the model transport is scripted. Native Ask/ToolsReady/LlmTurn reducers
        # still construct the pending batch and invoke the real ToolExec effect.
        directives = Enum.map(directives, &script_tool_response/1)
        {:ok, context, directives}

      result ->
        result
    end
  end

  defp script_tool_response(%Aikido.AiReact.Directives.LLMCall{} = request) do
    turn =
      Aikido.AI.Test.ResponseFixtures.tool_call_response([
        {"unreached", %{}, "capacity-call"}
      ])

    %Aikido.Directives.Emit{
      signal: %Aikido.Signal{
        type: "ai.react.llm.completed",
        data: %{request_id: request.request_id, iteration: request.iteration, turn: turn}
      }
    }
  end

  defp script_tool_response(directive), do: directive
end

defmodule Aikido.AICapacityTest.Agent do
  use Aikido.Agent

  agent do
    name "ai_capacity"
    middleware [Aikido.AICapacityTest.Observe]
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.AICapacityTest.Client do
  def generate_text(_, _, _),
    do: {:ok, Aikido.AI.Test.ResponseFixtures.final_answer_response("recovered")}
end

defmodule Aikido.AICapacityTest do
  use AikidoTest.Case, async: false
  @moduletag capture_log: true

  setup do
    start_supervised!(AikidoTest.Support.TestTracer)
    :ok
  end

  for kind <- [:model, :tool] do
    test "#{kind} outer task rejection settles without crashing the agent" do
      assert_outer_rejection(unquote(kind))
    end

    test "#{kind} inner attempt rejection returns a correlated result" do
      assert_inner_rejection(unquote(kind))
    end
  end

  defp assert_outer_rejection(kind) do
    request_id = unique_id("capacity")
    {pid, supervisor} = limited_runtime(2)

    if kind == :tool do
      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "ai.react.tool.completed",
          fn runtime ->
            {:ok, runtime.agent.state.ai}
          end,
          once: true
        )

      assert %{status: :failed} = launch_until_terminal(pid, kind, request_id, supervisor, 2)
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ai}}}, 5_000

      assert [%{tool_call_id: "capacity-call"}] =
               Enum.filter(ai.context.messages, &(&1.role == :tool))

      assert ai.request_id == request_id
      assert %{"error" => message} = Jason.decode!(tool_text(ai))
      assert is_binary(message)
    else
      assert %{status: :failed, error: :max_children, request_id: ^request_id} =
               launch_until_terminal(pid, kind, request_id, supervisor, 2)
    end

    assert_result_scope(kind, request_id)
    assert Process.alive?(pid)

    assert %{status: :completed, result: "recovered"} =
             launch_until_terminal(pid, :recover, unique_id("recovered"))

    await_task_shutdown(supervisor)
  end

  defp assert_inner_rejection(kind) do
    request_id = unique_id("capacity")
    {pid, supervisor} = limited_runtime(2)

    if kind == :tool do
      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "ai.react.tool.completed",
          fn runtime ->
            {:ok, runtime.agent.state.ai}
          end,
          once: true
        )

      assert %{status: :failed} = launch_until_terminal(pid, kind, request_id, supervisor, 1)
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ai}}}, 5_000

      assert [%{tool_call_id: "capacity-call"}] =
               Enum.filter(ai.context.messages, &(&1.role == :tool))

      assert ai.request_id == request_id
      assert %{"error" => message} = Jason.decode!(tool_text(ai))
      assert is_binary(message)
    else
      assert %{status: :failed, error: %RuntimeError{message: message}, request_id: ^request_id} =
               launch_until_terminal(pid, kind, request_id, supervisor, 1)

      assert message =~ "maximum number of tasks"
    end

    assert_result_scope(kind, request_id)
    assert Process.alive?(pid)
    await_task_shutdown(supervisor)
    assert {:ok, :responsive} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end)
  end

  defp await_task_shutdown(supervisor) do
    for pid <- Task.Supervisor.children(supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    assert Task.Supervisor.children(supervisor) == []
  end

  defp limited_runtime(limit) do
    instance = String.to_atom(unique_id("ai_capacity"))
    start_supervised!({Aikido, name: instance, max_tasks: limit, durable: durable_options()})

    pid = start_server(%{aikido: instance}, Aikido.AICapacityTest.Agent)
    {pid, Aikido.task_supervisor_name(instance)}
  end

  defp occupy(supervisor) do
    observer = self()

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        send(observer, {:occupied, self()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:occupied, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :release) end)
    pid
  end

  defp release(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp launch_until_terminal(pid, kind, id, supervisor \\ nil, blocked_slots \\ 0) do
    selector = fn runtime ->
      ai = runtime.agent.state.ai

      if ai.request_id == id and ai.status in [:completed, :failed],
        do: {:ok, ai},
        else: :skip
    end

    assert {:ok, ref} = Aikido.AgentServer.subscribe(pid, "ai.react.**", selector, once: true)
    assert {:ok, :launched} = launch(pid, kind, id, self())

    blockers =
      if kind == :recover do
        []
      else
        assert_receive {:tools_prepared, ^pid, ^id}, 5_000
        # Tool setup uses the same supervisor. Saturate only after its real work
        # has exited, leaving the rejection under test isolated to model/tool execution.
        await_task_shutdown(supervisor)
        blockers = Enum.map(List.duplicate(:slot, blocked_slots), fn _ -> occupy(supervisor) end)
        assert length(Task.Supervisor.children(supervisor)) == blocked_slots
        send(pid, {:release_prepared, id})
        blockers
      end

    try do
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ai}}}, 5_000
      ai
    after
      Enum.each(blockers, &release/1)
      Aikido.AgentServer.unsubscribe(pid, ref)
    end
  end

  defp launch(pid, kind, id, observer) do
    signal =
      Aikido.AiReact.Signals.Ask.new!(%{
        request_id: id,
        query: if(kind == :recover, do: "recover", else: "exercise capacity"),
        model: "offline",
        client: Aikido.AICapacityTest.Client,
        options: %{streaming: false, model_max_retries: 0}
      })
      |> Aikido.Signal.put_ctx(%{
        actor: %{id: "capacity-actor"},
        tenant: "capacity-tenant",
        tracer: AikidoTest.Support.TestTracer,
        context: %{shared: %{observer: observer, marker: "capacity", kind: kind}}
      })

    Aikido.AgentServer.call(pid, signal, fn _ -> {:ok, :launched} end)
  end

  defp assert_result_scope(kind, id) do
    type = if kind == :model, do: "ai.react.failed", else: "ai.react.tool.completed"
    assert_receive {:capacity_result, ^type, %{request_id: ^id}, context}, 5_000
    assert context.actor == %{id: "capacity-actor"}
    assert context.tenant == "capacity-tenant"
    assert context.context.shared.marker == "capacity"

    spans = AikidoTest.Support.TestTracer.get_spans()
    assert Enum.any?(spans, &match?({:start, _, {:custom, :aikido_signal}, ^type}, &1))
  end

  defp tool_text(ai) do
    ai.context.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.content)
    |> Enum.map_join(& &1.text)
  end
end
