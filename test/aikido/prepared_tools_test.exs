defmodule Aikido.PreparedToolsTest.Agent do
  use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

  agent do
    name "prepared_tools"
  end

  slices do
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.PreparedToolsTest.Client do
  alias Aikido.AI.Test.ResponseFixtures, as: Responses

  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model, self(), opts[:tools]})

    receive do
      :continue -> :ok
    end

    count = Enum.count(messages, &(&1.role == :tool))
    name = hd(opts[:tools]).name
    args = %{"input" => %{"a" => 2, "b" => 3}}

    response =
      case count do
        0 -> Responses.tool_call_response([{name, args, "one"}, {name, args, "two"}])
        2 -> Responses.tool_call_response([{name, args, "three"}])
        _ -> Responses.final_answer_response("done")
      end

    {:ok, response}
  end
end

defmodule Aikido.PreparedToolsTest do
  use AikidoTest.Case, async: false
  use Mimic
  alias Aikido.PreparedToolsTest.{Agent, Client}

  setup :set_mimic_global
  setup :verify_on_exit!

  test "one native build serves multiple model turns and parallel tools; restore rebuilds", ctx do
    expect(AshAi, :build_tools_and_registry, fn opts ->
      assert opts[:tools] == [:test_add]
      Mimic.call_original(AshAi, :build_tools_and_registry, [opts])
    end)

    id = unique_id()
    assert {:ok, pid} = start_test_agent(ctx, Agent, id: id)
    observer = self()

    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "work", options(observer)) end)
    assert_receive {:model, first, [%ReqLLM.Tool{name: "test_add"}]}, 5_000

    assert {:ok, {[_], %{"test_add" => callback}}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.prepared_tools})

    assert is_function(callback, 2)
    saved = Aikido.Durable.AgentServer.dump_state(:sys.get_state(pid).user_state)
    snapshot = Aikido.Durable.AgentServer.load_state(1, saved)
    refute functions?(snapshot)

    send(first, :continue)
    assert_receive {:model, second, [%ReqLLM.Tool{name: "test_add"}]}, 5_000
    send(second, :continue)
    assert_receive {:model, third, [%ReqLLM.Tool{name: "test_add"}]}, 5_000
    send(third, :continue)
    assert {:ok, "done"} = Task.await(task)

    assert {:ok, nil} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.prepared_tools})
    assert :ok = Aikido.stop_agent(ctx.aikido, pid)
    assert {:ok, restored} = start_test_agent(ctx, Agent, id: id)

    expect(AshAi, :build_tools_and_registry, fn opts ->
      assert opts[:tools] == [:test_multiply]
      Mimic.call_original(AshAi, :build_tools_and_registry, [opts])
    end)

    next =
      Task.async(fn ->
        Aikido.AI.ask_sync(
          restored,
          "next",
          options(observer) |> Keyword.put(:tools, [:test_multiply])
        )
      end)

    assert_receive {:model, worker, [%ReqLLM.Tool{name: "test_multiply"}]}, 5_000
    send(worker, :continue)
    assert {:ok, "done"} = Task.await(next)
  end

  test "late preparation results cannot restart a cancelled or replaced run" do
    state = %{
      status: :running,
      request_id: "new",
      tool_preparation: [:waiting],
      prepared_tools: nil
    }

    for current <- [state, %{state | status: :failed, request_id: "old"}] do
      signal =
        Jido.Signal.new!("ai.react.tools.ready", %{request_id: "old", prepared_tools: {[], %{}}})

      assert {:ok, ^current, []} =
               AikidoTest.NativeAction.run(
                 {Aikido.Slices.AiReact, :tools_ready},
                 signal,
                 current,
                 %{},
                 %{}
               )
    end
  end

  defp options(observer),
    do: [
      model: "offline",
      client: Client,
      tools: [:test_add],
      llm_opts: [observer: observer],
      timeout: 10_000
    ]

  defp functions?(value) when is_function(value), do: true

  defp functions?(value) when is_map(value),
    do: Enum.any?(Map.to_list(value), fn {k, v} -> functions?(k) || functions?(v) end)

  defp functions?(value) when is_list(value), do: Enum.any?(value, &functions?/1)
  defp functions?(value) when is_tuple(value), do: value |> Tuple.to_list() |> functions?()
  defp functions?(_), do: false
end
