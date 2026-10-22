defmodule Aikido.AiReact.Directives.VerifyTodos do
  @moduledoc "Runs one scoped application-owned Ash verification action outside the reducer."
  use Aikido.Directive

  typed_struct do
    field :revision, :integer do
      description "Todo revision whose evidence is being checked; newer work requires another verification."
      allow_nil? false
    end

    field :run_scope, :map do
      description "Opening actor and tenant used when verification is triggered by an external todo change."
      default %{}
      allow_nil? false
    end

    field :action, :tuple do
      description "Native Ash resource/action reference used to verify the proposed work."
      allow_nil? false
      constraints fields: [resource: [type: :atom], action: [type: :atom]]
    end

    field :answer, :term do
      description "Proposed model answer to verify."
    end

    field :todos, {:array, :term} do
      description "Blocking todo records supplied as verification evidence."
      default []
      allow_nil? false
    end

    field :metadata, :map do
      description "Application workflow configuration supplied to the verifier."
      default %{}
      allow_nil? false
    end

    field :request_id, :string do
      description "Run whose proposed answer is being verified."
      allow_nil? false
    end

    field :iteration, :integer do
      description "Model iteration correlated with this verification."
      allow_nil? false
    end

    field :timeout, :integer do
      description "Maximum duration of the verification action in milliseconds."
      allow_nil? false
    end

    field :tool_context, :map do
      description "Application context supplied to the scoped verification action."
      default %{}
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, signal, runtime) do
    owner = self()
    supervisor = Aikido.task_supervisor_name(runtime.aikido)
    scope = Map.merge(Aikido.Signal.ctx(signal), directive.run_scope)

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        Aikido.AiReact.CancellableTask.run_cancellable_attempts(
          owner,
          directive.request_id,
          supervisor,
          fn _, _ -> verify_work(directive, scope) end,
          timeout: directive.timeout,
          tracer: scope[:tracer]
        )
      end,
      payload: %{
        request_id: directive.request_id,
        iteration: directive.iteration,
        revision: directive.revision
      },
      success_type: "ai.react.todos.verified",
      error_type: "ai.react.failed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end

  defp verify_work(directive, scope) do
    {resource, action} = directive.action

    context =
      DeepMerge.deep_merge(directive.tool_context[:context] || %{}, scope[:context] || %{})

    options = Ash.Scope.to_opts(scope, context: context)

    with {:ok, verdict} <-
           resource
           |> Ash.ActionInput.for_action(
             action,
             %{answer: directive.answer, todos: directive.todos, metadata: directive.metadata},
             options
           )
           |> Ash.run_action(options) do
      if is_boolean(verdict),
        do: {:ok, verdict},
        else: {:error, "Todo verifier must return a boolean"}
    end
  end
end
