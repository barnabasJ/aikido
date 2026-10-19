defmodule Aikido.Slices.AiReact.Directives.PrepareTools do
  @moduledoc "Build Ash AI descriptions and callbacks once for a ReAct run."
  use Aikido.Directive

  typed_struct do
    field :tools, {:array, :atom}, default: [], allow_nil?: false
    field :tool_options, Aikido.Types.Native, constraints: [kind: :keyword_list], default: []
    field :request_id, :string, allow_nil?: false
  end

  @impl true
  def exec(directive, signal, runtime) do
    scope = Aikido.SignalCtx.ctx(signal)

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        prepared =
          directive.tool_options
          |> Keyword.merge(Ash.Scope.to_opts(scope))
          |> Keyword.put(:tools, directive.tools)
          |> AshAi.build_tools_and_registry()

        Jido.Signal.new!("ai.react.tools.ready", %{
          request_id: directive.request_id,
          prepared_tools: prepared
        })
      end,
      payload: %{request_id: directive.request_id},
      error_type: "ai.react.failed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end
end
