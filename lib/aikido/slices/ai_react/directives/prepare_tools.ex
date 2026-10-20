defmodule Aikido.Slices.AiReact.Directives.PrepareTools do
  @moduledoc "Build Ash AI descriptions and callbacks once for a ReAct run."
  use Aikido.Directive

  typed_struct do
    field :options, Aikido.Slices.AiReact.Options do
      description "Execution policy used to supervise preparation of the run's native Ash AI tools."
      default %Aikido.Slices.AiReact.Options{}
      allow_nil? false
    end

    field :tools, {:array, :atom} do
      description "Native Ash AI tool names whose descriptions and callbacks will be prepared."
      default []
      allow_nil? false
    end

    field :tool_options, {:array, :tuple} do
      description "Native Ash AI options used to resolve and prepare the tool registry."
      constraints items: [fields: [key: [type: :atom], value: [type: :term]]]
      default []
    end

    field :request_id, :string do
      description "Run identifier attached to the tool-preparation completion or failure signal."
      allow_nil? false
    end
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
          Aikido.Slices.AiReact.Execution.run(
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
