defmodule Aikido.AiReact.Directives.LLMCallTest.Signals.RunModel do
  use Aikido.Signal

  signal do
    type "test.model.run"

    schema do
      attribute :directive, Aikido.Types.Directive do
        description "Prepared model request for this scenario."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest.Actions.RunModel do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{
        status: :running,
        request_id: input.arguments.directive.request_id
      },
      directives: [input.arguments.directive]
    )
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest.Actions.RecordTurn do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{
        status: :completed,
        last_signal: input.context.aikido.signal
      }
    )
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest.Actions.RecordFailure do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{status: :failed, last_signal: input.context.aikido.signal}
    )
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest.Actions.RecordHandoff do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    Aikido.Types.ActionResult.new(
      changes: %{
        status: :completed,
        last_signal: input.context.aikido.signal
      }
    )
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest.Agent do
  use Aikido.Agent

  agent do
    name "model_attempt_scenario"
    path :ai
    persistence :temporary

    schema do
      attribute :request_id, :string do
        description "Correlation of the current model attempt."
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Whether the model attempt is running, completed or failed."
        default :idle
        allow_nil? false
      end

      attribute :last_signal, :term do
        description "Outcome received through the agent's routed model action."
      end
    end

    route Aikido.AiReact.Directives.LLMCallTest.Signals.RunModel,
          Aikido.AiReact.Directives.LLMCallTest.Actions.RunModel

    route Aikido.AiReact.Signals.LlmTurn,
          Aikido.AiReact.Directives.LLMCallTest.Actions.RecordTurn, public?: false

    route Aikido.AiReact.Signals.Failed,
          Aikido.AiReact.Directives.LLMCallTest.Actions.RecordFailure, public?: false

    route Aikido.AiReact.Signals.HandoffCompleted,
          Aikido.AiReact.Directives.LLMCallTest.Actions.RecordHandoff, public?: false
  end
end

defmodule Aikido.AiReact.Directives.LLMCallTest do
  # async: false because the directive's executor spawns a Task that
  # calls `ReqLLM.Generation.generate_text/3`. The Mimic stub on that
  # function must be visible from the spawned process — `set_mimic_global/0`
  # provides that, and global mode is mutually exclusive with async tests.
  use AikidoTest.Case, async: false
  use Mimic

  import Aikido.AI.Test.ResponseFixtures

  alias Aikido.AiReact.Directives.LLMCall

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

  defp run_model(context, directive) do
    agent = start_server(context, __MODULE__.Agent)
    signal = Aikido.Signal.new!("test.model.run", %{directive: directive})

    {:ok, completed} =
      Aikido.AgentServer.call_until(agent, signal, "ai.react.**", fn runtime ->
        state = runtime.agent.state.ai
        if state.status in [:completed, :failed], do: {:ok, state.last_signal}, else: :skip
      end)

    completed
  end

  test "casts execution options before starting model work" do
    assert %Aikido.AiReact.Options{streaming: true, model_timeout_ms: 5_000} =
             directive(options: %{streaming: "true", model_timeout_ms: "5000"}).options

    assert {:error, _} =
             LLMCall.new(
               model: "offline",
               context: Context.new(),
               request_id: "invalid-options",
               options: %{model_timeout_ms: 0}
             )
  end

  test "spawns a task, calls ReqLLM, and casts ai.react.llm.completed back", context do
    test_pid = self()

    expect(ReqLLM.Generation, :generate_text, fn _model, messages, opts ->
      send(test_pid, {:reqllm_called, length(messages), Keyword.fetch!(opts, :tools)})
      {:ok, final_answer_response("ok")}
    end)

    signal = run_model(context, directive())

    assert_receive {:reqllm_called, 1, [_]}, 1_000

    assert signal.type == "ai.react.llm.completed"
    assert signal.data.request_id == "req_1"
    assert %ReqLLM.Response{} = signal.data.turn
    assert ReqLLM.Response.text(signal.data.turn) == "ok"
  end

  test "casts ai.react.failed when ReqLLM returns an error", context do
    expect(ReqLLM.Generation, :generate_text, fn _model, _messages, _opts ->
      {:error, :rate_limited}
    end)

    signal = run_model(context, directive())

    assert signal.type == "ai.react.failed"
    assert signal.data == %{reason: :rate_limited, request_id: "req_1"}
  end

  test "native provider failures preserve public diagnostics and omit private exception fields",
       context do
    cases = [
      {ReqLLM.Error.API.Request.exception(
         status: 401,
         reason: "private-provider-key",
         headers: [{"authorization", "private-provider-key"}]
       ), "401", "credential"},
      {ReqLLM.Error.API.Request.exception(
         status: 429,
         reason: "private-provider-key",
         request_body: %{key: "private-provider-key"}
       ), "429", "quota"},
      {ReqLLM.Error.API.Request.exception(status: 503, reason: "private-provider-key"), "503",
       "backoff"},
      {ReqLLM.Error.API.Response.exception(
         status: 200,
         reason: "private-provider-key",
         response_body: "private-provider-key"
       ), "no usable model response", "compatibility"},
      {ReqLLM.Error.API.Timeout.exception(kind: :receive, timeout: 30_000), "30000ms (receive)",
       "deadline"}
    ]

    for {failure, description, recovery} <- cases do
      expect(ReqLLM.Generation, :generate_text, fn _, _, _ -> {:error, failure} end)
      signal = run_model(context, directive())
      assert signal.type == "ai.react.failed"
      assert %Aikido.AiReact.Errors.ProviderRequestFailed{} = error = signal.data.reason
      assert Exception.message(error) =~ description
      assert AshAi.ToToolError.to_tool_error(error) =~ recovery
      assert AshLua.Error.to_error(error).message =~ recovery
      refute inspect(error) =~ "private-provider-key"
    end
  end

  test "handoff calls disable streaming and report a separately correlated document", context do
    expect(ReqLLM.Generation, :generate_text, fn _, _, opts ->
      assert opts[:tools] == []
      {:ok, final_answer_response("Next action: continue.")}
    end)

    handoff = directive(mode: :handoff, handoff_id: 7, tools: [], options: %{streaming: true})

    signal = run_model(context, handoff)

    assert signal.type == "ai.react.context_handoff.completed"
    assert signal.data.request_id == "req_1"
    assert signal.data.handoff_id == 7
  end
end
