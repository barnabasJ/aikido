defmodule Aikido.Slices.AiReact.Directives.LLMCallTest do
  # async: false because the directive's executor spawns a Task that
  # calls `ReqLLM.Generation.generate_text/3`. The Mimic stub on that
  # function must be visible from the spawned process — `set_mimic_global/0`
  # provides that, and global mode is mutually exclusive with async tests.
  use AikidoTest.Case, async: false
  use Mimic

  import Aikido.AI.Test.ResponseFixtures

  alias Aikido.Slices.AiReact.Directives.LLMCall

  alias ReqLLM.Context

  setup :set_mimic_global
  setup :verify_on_exit!

  defp directive(opts \\ []) do
    LLMCall.new!(
      mode: Keyword.get(opts, :mode, :normal),
      handoff_id: Keyword.get(opts, :handoff_id),
      options: Keyword.get(opts, :options, %{}),
      model: Keyword.get(opts, :model, "anthropic:claude-haiku-4-5-20251001"),
      context: Keyword.get(opts, :context, Context.new([Context.user("hi")])),
      tools:
        AshAi.build_tools_and_registry(
          otp_app: :aikido,
          tools: Keyword.get(opts, :tools, [:test_add])
        )
        |> elem(0),
      request_id: Keyword.get(opts, :request_id, "req_1"),
      llm_opts: Keyword.get(opts, :llm_opts, max_tokens: 64)
    )
  end

  defp fake_state(aikido), do: %{id: "stub-agent", aikido: aikido}

  # Stand-in for the agent process: forwards every cast it receives back
  # to the test pid so we can assert on the cast signal shape.
  defp spawn_agent_stub(target_pid) do
    spawn_link(fn -> forward(target_pid) end)
  end

  defp forward(target) do
    receive do
      {:"$gen_cast", {:signal, signal}} ->
        send(target, {:cast, signal})
        forward(target)

      {:"$gen_call", from, {:subscribe, _, _, _, _, _}} ->
        GenServer.reply(from, {:ok, make_ref()})
        forward(target)

      {:"$gen_call", from, {:read_state_with_selector, selector}} ->
        GenServer.reply(
          from,
          selector.(%{agent: %{state: %{ai: %{request_id: "req_1", status: :running}}}})
        )

        forward(target)

      {:run, fun, from} ->
        send(from, {:run_done, fun.()})
        forward(target)

      _ ->
        forward(target)
    end
  end

  defp run_in(pid, fun) do
    send(pid, {:run, fun, self()})

    receive do
      {:run_done, result} -> result
    after
      1_000 -> :timeout
    end
  end

  test "casts execution options before starting model work" do
    assert %Aikido.Slices.AiReact.Options{streaming: true, model_timeout_ms: 5_000} =
             directive(options: %{streaming: "true", model_timeout_ms: "5000"}).options

    assert {:error, _} =
             LLMCall.new(
               model: "offline",
               context: Context.new(),
               request_id: "invalid-options",
               options: %{model_timeout_ms: 0}
             )
  end

  test "spawns a task, calls ReqLLM, and casts ai.react.llm.completed back", %{aikido: aikido} do
    test_pid = self()

    expect(ReqLLM.Generation, :generate_text, fn _model, messages, opts ->
      send(test_pid, {:reqllm_called, length(messages), Keyword.fetch!(opts, :tools)})
      {:ok, final_answer_response("ok")}
    end)

    agent = spawn_agent_stub(test_pid)

    :ok =
      run_in(agent, fn ->
        Aikido.Directive.exec(directive(), Aikido.Signal.new!("input", %{}), fake_state(aikido))
      end)

    assert_receive {:reqllm_called, 1, [_]}, 1_000
    assert_receive {:cast, signal}, 1_000

    assert signal.type == "ai.react.llm.completed"
    assert signal.data.request_id == "req_1"
    assert %ReqLLM.Response{} = signal.data.turn
    assert ReqLLM.Response.text(signal.data.turn) == "ok"
  end

  test "casts ai.react.failed when ReqLLM returns an error", %{aikido: aikido} do
    test_pid = self()

    expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
      {:error, :rate_limited}
    end)

    agent = spawn_agent_stub(test_pid)

    :ok =
      run_in(agent, fn ->
        Aikido.Directive.exec(directive(), Aikido.Signal.new!("input", %{}), fake_state(aikido))
      end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.failed"
    assert signal.data == %{reason: :rate_limited, request_id: "req_1"}
  end

  test "handoff calls disable streaming and report a separately correlated document", %{
    aikido: aikido
  } do
    expect(ReqLLM.Generation, :generate_text, fn _, _, opts ->
      assert opts[:tools] == []
      {:ok, final_answer_response("Next action: continue.")}
    end)

    agent = spawn_agent_stub(self())

    handoff = directive(mode: :handoff, handoff_id: 7, tools: [], options: %{streaming: true})

    assert :ok =
             run_in(agent, fn ->
               Aikido.Directive.exec(
                 handoff,
                 Aikido.Signal.new!("input", %{}),
                 fake_state(aikido)
               )
             end)

    assert_receive {:cast, signal}, 1_000
    assert signal.type == "ai.react.context_handoff.completed"
    assert signal.data.request_id == "req_1"
    assert signal.data.handoff_id == 7
  end
end
