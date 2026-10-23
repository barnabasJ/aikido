defmodule Aikido.AiReact.Directives.PrepareTools do
  @moduledoc "Build Ash AI descriptions and callbacks once for a ReAct run."
  use Aikido.Directive

  typed_struct do
    field :generation, :integer do
      description "Tool preparation generation rejected if superseded by a refresh."
      default 0
      allow_nil? false
    end

    field :metadata, :map do
      description "Application configuration passed to the native preparation action."
      default %{}
      allow_nil? false
    end

    field :tool_context, :map do
      description "Application tool context supplied to the scoped preparation action."
      default %{}
      allow_nil? false
    end

    field :deadline_at, :integer do
      description "Absolute Unix-millisecond deadline; this effect cannot extend the owning run's remaining budget."
      constraints min: 1
    end

    field :options, Aikido.AiReact.Options do
      description "Execution policy used to supervise preparation of the run's native Ash AI tools."
      default %Aikido.AiReact.Options{}
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
      work: fn -> prepare_tools_and_build_ready_signal(directive, scope, owner, supervisor) end,
      payload: %{request_id: directive.request_id, generation: directive.generation},
      error_type: "ai.react.failed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end

  defp prepare_tools_and_build_ready_signal(directive, scope, owner, supervisor) do
    with {:ok, prepared} <-
           Aikido.AiReact.CancellableTask.run_cancellable_attempts(
             owner,
             directive.request_id,
             supervisor,
             fn _, _ -> build_native_tools_and_registry(directive, scope) end,
             tracer: scope[:tracer],
             generation: directive.generation,
             timeout: directive.options.model_timeout_ms,
             deadline_at: directive.deadline_at
           ) do
      Aikido.Signal.new!("ai.react.tools.ready", %{
        request_id: directive.request_id,
        generation: directive.generation,
        prepared_tools: prepared
      })
    end
  end

  defp build_native_tools_and_registry(directive, scope) do
    defaults = Keyword.put(directive.tool_options, :tools, directive.tools)

    context =
      DeepMerge.deep_merge(directive.tool_context[:context] || %{}, scope[:context] || %{})

    scope_options = Ash.Scope.to_opts(scope, context: context)

    with {:ok, options} <- prepare_native_options(directive, defaults, scope_options) do
      prepared =
        options
        |> Keyword.merge(scope_options)
        |> Keyword.drop([:tracer, :authorize?])
        |> AshAi.build_tools_and_registry()

      {:ok, prepared}
    end
  end

  defp prepare_native_options(%{options: %{tool_preparation: nil}}, defaults, _scope),
    do: {:ok, defaults}

  defp prepare_native_options(
         %{options: %{tool_preparation: {resource, action}}} = directive,
         defaults,
         scope
       ) do
    with {:ok, options} <-
           resource
           |> Ash.ActionInput.for_action(
             action,
             %{options: defaults, metadata: directive.metadata},
             scope
           )
           |> Ash.run_action(scope) do
      if Keyword.keyword?(options),
        do: {:ok, options},
        else: {:error, "Tool preparation must return native Ash AI keyword options"}
    end
  end
end
