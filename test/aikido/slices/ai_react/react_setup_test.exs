defmodule Aikido.ReactSetupTest.Agent do
  use Aikido.Agent

  agent do
    name "react_setup"
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.ReactSetupTest.Client do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model_started, messages})
    {:ok, Aikido.AI.Test.ResponseFixtures.final_answer_response("done")}
  end
end

defmodule Aikido.ReactSetupTest do
  use AikidoTest.Case, async: false
  use Mimic
  alias Aikido.ReactSetupTest.{Agent, Client}
  @moduletag capture_log: true

  setup :set_mimic_global
  setup :verify_on_exit!

  test "setup gates the model and consumes queued messages and deliveries before its first request",
       ctx do
    observer = self()
    hold_preparation(observer)
    pid = start_server(ctx, Agent)
    opts = options(observer) ++ [actor: %{id: "alice"}, tenant: "workspace"]
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "initial", opts) end)
    assert_receive {:preparing, worker}, 5_000

    assert {:ok, %{status: :setup} = setup} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})

    refute_received {:model_started, _}
    assert {:error, _} = Aikido.AI.ask(pid, "another start", opts)

    replace_context = Aikido.Signal.new!("ai.react.replace_context", %{messages: []})

    assert {:error, _} =
             Aikido.AgentServer.call(pid, replace_context, fn _ -> {:ok, :unexpected} end)

    assert {:error, _} =
             Aikido.AI.queue_message(pid, "wrong actor", actor: %{id: "bob"}, tenant: "workspace")

    assert {:ok, :queued} =
             Aikido.AI.queue_message(pid, "queued", actor: %{id: "alice"}, tenant: "workspace")

    delivery =
      Aikido.Signal.new!("ai.react.deliver", %{
        text: "delivered",
        request_id: "delivery",
        metadata: %{step: "app"}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "alice"}, tenant: "workspace"})

    assert {:ok, :accepted} = Aikido.AgentServer.call(pid, delivery, fn _ -> {:ok, :accepted} end)

    assert {:ok, ["queued", "delivered"]} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.queued_messages})

    restored = setup |> Aikido.Slices.AiReact.externalize() |> Aikido.Slices.AiReact.reinstate()
    assert restored.status == :failed
    assert restored.error == :interrupted

    send(worker, :finish_setup)
    assert_receive {:model_started, messages}, 5_000

    assert Enum.map(messages, fn message -> Enum.map_join(message.content, & &1.text) end) == [
             "initial",
             "queued",
             "delivered"
           ]

    assert {:ok, "done"} = Task.await(task)

    assert {:ok, %{queued_messages: [], run_metadata: %{deliveries: [%{request_id: "delivery"}]}}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
  end

  test "cancelling setup kills preparation, ignores late readiness, and permits a new run", ctx do
    observer = self()
    hold_preparation(observer)
    pid = start_server(ctx, Agent)
    task = Task.async(fn -> Aikido.AI.ask_sync(pid, "cancel me", options(observer)) end)
    assert_receive {:preparing, worker}, 5_000
    monitor = Process.monitor(worker)

    assert {:ok, %{status: :setup, request_id: id}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})

    assert :ok = Aikido.AI.cancel(pid, id)
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    late =
      Aikido.Signal.new!("ai.react.tools.ready", %{request_id: id, prepared_tools: {[], %{}}})

    assert {:ok, :failed} = Aikido.AgentServer.call(pid, late, &{:ok, &1.agent.state.ai.status})
    refute_received {:model_started, _}

    expect(AshAi, :build_tools_and_registry, fn opts ->
      Mimic.call_original(AshAi, :build_tools_and_registry, [opts])
    end)

    assert {:ok, "done"} = Aikido.AI.ask_sync(pid, "try again", options(observer))
    assert_receive {:model_started, _}, 5_000
  end

  test "preparation failure settles setup without starting the model", ctx do
    expect(AshAi, :build_tools_and_registry, fn _ -> raise "setup failed" end)
    pid = start_server(ctx, Agent)

    assert {:error, %RuntimeError{message: "setup failed"}} =
             Aikido.AI.ask_sync(pid, "fail", options(self()))

    assert {:ok, %{status: :failed, prepared_tools: nil, tool_preparation: []}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})

    refute_received {:model_started, _}
  end

  defp hold_preparation(observer) do
    expect(AshAi, :build_tools_and_registry, fn opts ->
      send(observer, {:preparing, self()})

      receive do
        :finish_setup -> Mimic.call_original(AshAi, :build_tools_and_registry, [opts])
      end
    end)
  end

  defp options(observer),
    do: [
      model: "offline",
      client: Client,
      tools: [:test_add],
      llm_opts: [observer: observer],
      timeout: 10_000
    ]
end
