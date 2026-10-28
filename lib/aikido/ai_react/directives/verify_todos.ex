defmodule Aikido.AiReact.Directives.VerifyTodos do
  @moduledoc "Runs one scoped application-owned Ash verification action outside the reducer."
  use Aikido.Directive

  typed_struct do
    field :deadline_at, :integer do
      description "Absolute Unix-millisecond deadline inherited from the run being verified."
      constraints min: 1
    end

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

    field :data, Aikido.AiReact.VerifierData do
      description "Private native resource carrying data for an action that declares the optional data argument."
    end

    field :final_answer?, :boolean do
      description "Whether this verification originates from a newly adopted model final answer."
      default false
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

    identity = %{
      agent_pid: owner,
      agent_id: runtime.id,
      agent_resource: runtime.agent_module,
      aikido: runtime.aikido,
      partition: runtime.partition,
      request_id: directive.request_id
    }

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        Aikido.AiReact.CancellableTask.run_cancellable_attempts(
          owner,
          directive.request_id,
          supervisor,
          fn _, _ -> verify_work(directive, scope, identity) end,
          timeout: directive.timeout,
          deadline_at: directive.deadline_at,
          tracer: scope[:tracer]
        )
      end,
      payload: %{
        request_id: directive.request_id,
        iteration: directive.iteration,
        revision: directive.revision,
        final_answer?: directive.final_answer?
      },
      success_type: "ai.react.todos.verified",
      error_type: "ai.react.failed"
    }

    Aikido.Directives.AsyncTask.exec(task, signal, runtime)
  end

  defp verify_work(directive, scope, identity) do
    {resource, action} = directive.action

    context =
      DeepMerge.deep_merge(directive.tool_context[:context] || %{}, scope[:context] || %{})
      |> put_runtime_identity(identity)

    options = Ash.Scope.to_opts(scope, context: context)

    with {:ok, verdict} <-
           resource
           |> Ash.ActionInput.for_action(
             action,
             verification_arguments(resource, action, directive),
             options
           )
           |> Ash.run_action(options) do
      cast_verification_result(verdict)
    end
  end

  defp verification_arguments(resource, action, directive) do
    arguments = %{answer: directive.answer, todos: directive.todos, metadata: directive.metadata}

    case Ash.Resource.Info.action(resource, action) do
      %{arguments: declared} ->
        if Enum.any?(declared, &(&1.name == :data)),
          do: Map.put(arguments, :data, verifier_data_value(directive.data)),
          else: arguments

      _ ->
        arguments
    end
  end

  defp put_runtime_identity(context, identity) do
    application =
      case Map.get(context, :aikido) do
        value when is_map(value) -> value
        _ -> %{}
      end

    Map.put(context, :aikido, Map.merge(application, identity))
  end

  defp verifier_data_value(nil), do: nil
  defp verifier_data_value(%{value: value}), do: value

  defp cast_verification_result(verdict) when is_boolean(verdict) or is_map(verdict) do
    case Ash.Type.cast_input(Aikido.AiReact.Types.TodoVerificationResult, verdict) do
      {:ok, result} -> {:ok, result}
      _ -> invalid_verification_result()
    end
  end

  defp cast_verification_result(_verdict), do: invalid_verification_result()

  defp invalid_verification_result,
    do: {:error, "Todo verifier must return a boolean or valid TodoVerification"}
end
