defmodule AikidoTest.ReactQuint.Agent do
  @moduledoc "A real mounted ReAct agent for pure model replay."
  use Aikido.Agent

  agent do
    name "quint_react"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule AikidoTest.ReactQuint.Adapter do
  @moduledoc "Replays model transitions through a real mounted ReAct slice and native agent pipeline."
  use AshQuint.Adapter
  import ExUnit.Assertions, only: [assert: 1]
  alias Aikido.AgentServer
  alias AshQuint.Step

  @impl true
  def init(_trace, _opts) do
    agent = AikidoTest.ReactQuint.Agent.initialize!()
    router = Aikido.Signal.Router.new!(Aikido.Agent.Info.routes(AikidoTest.ReactQuint.Agent))
    {:ok, %{agent: agent, router: router, directives: [], request: "not-started"}}
  end

  @impl true
  def step(ctx, %Step{action_taken: "Stream", nondet_picks: picks}) do
    signal =
      Aikido.AiReact.Signals.Stream.new!(%{
        request_id: if(picks["current"], do: ctx.request, else: "obsolete"),
        iteration: picks["turn"],
        attempt: picks["attempt"],
        sequence: picks["sequence"],
        text: "x"
      })

    {:ok, {:ok, :processed}, dispatch(ctx, signal)}
  end

  def step(ctx, %Step{action_taken: "Cancel"}) do
    {:ok, {:ok, :processed}, dispatch(ctx, Aikido.AiReact.Signals.Cancel.new!(%{}))}
  end

  def step(ctx, %Step{action_taken: "Complete"}) do
    response = Aikido.AI.Test.ResponseFixtures.final_answer_response("done")

    signal =
      Aikido.AiReact.Signals.LlmTurn.new!(%{
        request_id: ctx.request,
        iteration: 1,
        turn: response
      })

    {:ok, {:ok, :processed}, dispatch(ctx, signal)}
  end

  def step(ctx, %Step{action_taken: "Begin"}), do: {:ok, {:ok, :processed}, begin_run(ctx)}

  def step(ctx, %Step{action_taken: "Ready", nondet_picks: picks}) do
    signal =
      Aikido.AiReact.Signals.ToolsReady.new!(%{
        request_id: if(picks["current"], do: ctx.request, else: "obsolete"),
        generation: ctx.agent.state.ai.tools_generation + if(picks["fresh"], do: 0, else: 1),
        prepared_tools: {[], %{}}
      })

    {:ok, {:ok, :processed}, dispatch(ctx, signal)}
  end

  @impl true
  def project(ctx) do
    ai = ctx.agent.state.ai

    %{
      "status" => to_string(ai.status),
      "generation" => ai.tools_generation,
      "attempt" => ai.stream_attempt,
      "sequence" => if(ai.stream_receipt, do: ai.stream_receipt.sequence, else: 0),
      "text" => String.codepoints(ai.streaming_text),
      "iteration" => ai.iteration,
      "effects" => Enum.map(ctx.directives, &(Module.split(&1.__struct__) |> List.last()))
    }
  end

  defp begin_run(ctx) do
    request = Ash.UUIDv7.generate()

    signal =
      Aikido.AiReact.Signals.Ask.new!(%{
        request_id: request,
        query: "controlled model turn",
        model: "offline",
        client: ReqLLM.Generation,
        options: %{streaming: false}
      })

    ctx = dispatch(ctx, signal)
    [%Aikido.AiReact.Directives.PrepareTools{request_id: ^request}] = ctx.directives

    Map.put(ctx, :request, request)
  end

  defp dispatch(ctx, signal) do
    {:ok, targets} = Aikido.Signal.Router.route(ctx.router, signal)
    targets = Enum.map(targets, &{&1, signal.data})

    scope = %{
      agent: ctx.agent,
      agent_module: AikidoTest.ReactQuint.Agent,
      agent_id: ctx.agent.id,
      authorize?: false
    }

    {:ok, %{agent: adopted}, directives} = AgentServer.apply_actions(signal, scope, targets)
    Enum.each(directives, &check_descriptor(&1, adopted.state.ai))
    %{ctx | agent: adopted, directives: directives}
  end

  defp check_descriptor(%Aikido.AiReact.Directives.PrepareTools{} = directive, ai) do
    assert directive.request_id == ai.request_id
    assert directive.generation == ai.tools_generation
  end

  defp check_descriptor(%Aikido.AiReact.Directives.LLMCall{} = directive, ai) do
    assert directive.request_id == ai.request_id
    assert directive.iteration == ai.iteration + 1
    assert directive.context == ai.context
    assert directive.model == ai.model
    assert directive.options == ai.options
    assert directive.tools == []
  end

  defp check_descriptor(_directive, _ai), do: :ok
end
