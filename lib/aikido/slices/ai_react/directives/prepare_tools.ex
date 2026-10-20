defmodule Aikido.Slices.AiReact.Directives.PrepareTools do
  @moduledoc "Build Ash AI descriptions and callbacks once for a ReAct run."
  use Aikido.Directive

  typed_struct do
    field :options, Aikido.AI.Options, default: %Aikido.AI.Options{}, allow_nil?: false
    field :tools, {:array, :atom}, default: [], allow_nil?: false

    field :tool_options, {:array, :tuple},
      constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]],
      default: []

    field :request_id, :string, allow_nil?: false
  end

  @impl true
  def exec(directive, signal, runtime) do
    scope = Aikido.Signal.ctx(signal)

    owner = self()
    supervisor = Aikido.task_supervisor_name(runtime.aikido)

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        options = directive.options

        result =
          Aikido.AI.Execution.run(
            owner,
            directive.request_id,
            supervisor,
            fn _, _ ->
              prepared =
                directive.tool_options
                |> Keyword.merge(Ash.Scope.to_opts(scope, context: scope[:context] || %{}))
                |> Keyword.put(:tools, directive.tools)
                |> Keyword.drop([:tracer, :authorize?])
                |> AshAi.build_tools_and_registry()

              {:ok, prepared}
            end,
            tracer: scope[:tracer],
            timeout: options.model_timeout_ms
          )

        case result do
          {:ok, prepared} ->
            Aikido.Signal.new!("ai.react.tools.ready", %{
              request_id: directive.request_id,
              prepared_tools: prepared
            })

          {:error, reason} ->
            {:error, reason}
        end
      end,
      payload: %{request_id: directive.request_id},
      error_type: "ai.react.failed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end
end
