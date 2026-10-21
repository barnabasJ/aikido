defmodule Aikido.AICapacityTest.Launch do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    runtime = input.context.aikido
    request_id = input.arguments.request_id
    tool_call = %{id: "capacity-call", name: "unreached", arguments: %{}}
    context = ReqLLM.Context.new([ReqLLM.Context.user("capacity")])

    {context, pending, effect} =
      case input.arguments.kind do
        :model ->
          {context, [],
           %Aikido.AiReact.Directives.LLMCall{
             model: "offline",
             client: Aikido.AICapacityTest.Client,
             context: context,
             request_id: request_id
           }}

        :tool ->
          context =
            ReqLLM.Context.append(
              context,
              ReqLLM.Context.assistant("",
                tool_calls: [
                  %ReqLLM.ToolCall{
                    id: tool_call.id,
                    function: %{name: tool_call.name, arguments: "{}"}
                  }
                ]
              )
            )

          {context, [tool_call],
           %Aikido.AiReact.Directives.ToolExec{
             tool_call: tool_call,
             request_id: request_id
           }}
      end

    ai =
      runtime.agent.state.ai
      |> Map.merge(%{
        status: :running,
        request_id: request_id,
        model: "offline",
        client: Aikido.AICapacityTest.Client,
        context: context,
        pending_tool_calls: pending,
        prepared_tools: {[], %{}}
      })
      |> Aikido.AiReact.Context.replace_context(context)

    Aikido.Types.ActionResult.new(
      state: %Aikido.Types.SliceUpdate{slices: %{ai: ai}},
      directives: [effect]
    )
  end
end

defmodule Aikido.AICapacityTest.Observe do
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _opts, next) do
    if signal.type in ["ai.react.failed", "ai.react.tool.completed"] do
      send(context.context.shared.observer, {:capacity_result, signal.type, signal.data, context})
    end

    next.(signal, context)
  end
end

defmodule Aikido.AICapacityTest.Agent do
  use Aikido.Agent

  agent do
    name "ai_capacity"
    middleware [Aikido.AICapacityTest.Observe]
    slice :ai, Aikido.AiReact.Slice
    route "capacity.launch", :launch
  end

  actions do
    action :launch, Aikido.Types.ActionResult do
      argument :state, :term
      argument :kind, :atom, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      run Aikido.AICapacityTest.Launch
    end
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
    {pid, supervisor} = limited_runtime(2)
    blockers = for _ <- 1..2, do: occupy(supervisor)
    request_id = unique_id("capacity")

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

      assert %{status: :failed} = launch_until_terminal(pid, kind, request_id)
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ai}}}, 5_000

      assert [%{tool_call_id: "capacity-call"}] =
               Enum.filter(ai.context.messages, &(&1.role == :tool))

      assert ai.request_id == request_id
      assert %{"error" => message} = Jason.decode!(tool_text(ai))
      assert is_binary(message)
    else
      assert %{status: :failed, error: :max_children, request_id: ^request_id} =
               launch_until_terminal(pid, kind, request_id)
    end

    assert_result_scope(kind, request_id)
    assert Process.alive?(pid)
    Enum.each(blockers, &release/1)

    assert %{status: :completed, result: "recovered"} =
             launch_until_terminal(pid, :model, unique_id("recovered"))

    await_task_shutdown(supervisor)
  end

  defp assert_inner_rejection(kind) do
    {pid, supervisor} = limited_runtime(1)
    request_id = unique_id("capacity")

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

      assert %{status: :failed} = launch_until_terminal(pid, kind, request_id)
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, ai}}}, 5_000

      assert [%{tool_call_id: "capacity-call"}] =
               Enum.filter(ai.context.messages, &(&1.role == :tool))

      assert ai.request_id == request_id
      assert %{"error" => message} = Jason.decode!(tool_text(ai))
      assert is_binary(message)
    else
      assert %{status: :failed, error: %RuntimeError{message: message}, request_id: ^request_id} =
               launch_until_terminal(pid, kind, request_id)

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

  defp launch_until_terminal(pid, kind, id) do
    observer = self()

    assert {:ok, ai} =
             Aikido.AgentServer.call_until(
               pid,
               fn -> launch(pid, kind, id, observer) end,
               "ai.react.**",
               fn runtime ->
                 ai = runtime.agent.state.ai

                 if ai.request_id == id and ai.status in [:completed, :failed],
                   do: {:ok, ai},
                   else: :skip
               end
             )

    ai
  end

  defp launch(pid, kind, id, observer) do
    signal =
      Aikido.Signal.new!("capacity.launch", %{kind: kind, request_id: id})
      |> Aikido.Signal.put_ctx(%{
        actor: %{id: "capacity-actor"},
        tenant: "capacity-tenant",
        tracer: AikidoTest.Support.TestTracer,
        context: %{shared: %{observer: observer, marker: "capacity"}}
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
