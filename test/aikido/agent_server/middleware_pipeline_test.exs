defmodule AikidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware do
  @moduledoc false
  use Aikido.Middleware
  @impl true
  def on_signal(signal, ctx, opts, next) do
    tag = opts[:tag] || :default
    ctx = Map.update(ctx, :tags, [tag], &(&1 ++ [tag]))
    next.(signal, ctx)
  end
end

defmodule AikidoTest.AgentServer.MiddlewarePipelineTest.InspectAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    ctx = input.context.aikido
    Aikido.ActionResult.new(state: %{slice | last_tags: ctx[:tags] || []}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.MiddlewarePipelineTest.InspectAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "inspect"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.MiddlewarePipelineTest.InspectAction.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.MiddlewarePipelineTest.MiddlewareAgent do
  @moduledoc false
  use Aikido.Agent,
    middleware: [
      {AikidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware, %{tag: :outer}},
      {AikidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware, %{tag: :inner}}
    ]

  agent do
    name "middleware_pipeline_agent"
    path :app

    schema do
      attribute :last_tags, {:array, :term}, default: []
    end
  end

  signal_routes do
    route "inspect", AikidoTest.AgentServer.MiddlewarePipelineTest.InspectAction
  end
end

defmodule AikidoTest.AgentServer.MiddlewarePipelineTest do
  use AikidoTest.Case, async: false

  defp inspect_sig do
    {:ok, sig} = Jido.Signal.new(%{type: "inspect", source: "/test", data: %{}})
    sig
  end

  describe("compile-time middleware chain") do
    test("outside-in composition order: outer middleware sees signal first", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.MiddlewarePipelineTest.MiddlewareAgent
        )

      :ok = Aikido.AgentServer.await_ready(pid)
      {:ok, agent} = Aikido.AgentServer.call(pid, inspect_sig(), fn s -> {:ok, s.agent} end)
      assert agent.state.app.last_tags == [:outer, :inner]
    end
  end

  describe("runtime middleware injection") do
    test("options-supplied middleware appends to the compile-time chain", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.MiddlewarePipelineTest.MiddlewareAgent,
          middleware: [
            {AikidoTest.AgentServer.MiddlewarePipelineTest.TaggingMiddleware, %{tag: :runtime}}
          ]
        )

      :ok = Aikido.AgentServer.await_ready(pid)
      {:ok, agent} = Aikido.AgentServer.call(pid, inspect_sig(), fn s -> {:ok, s.agent} end)
      assert :runtime in agent.state.app.last_tags
      assert agent.state.app.last_tags == [:outer, :inner, :runtime]
    end
  end
end
