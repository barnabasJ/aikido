defmodule Aikido.AiReact.ModelPreparation do
  @moduledoc "Native model preparation under the receiving runtime's immutable activation scope."

  @doc "Select resource-owned preparation before the mutable option fallback, without rewriting either."
  def descriptor(runtime, fallback) do
    action =
      case Aikido.AI.Info.ai_model_preparation(runtime.agent_module) do
        {:ok, configured} -> configured
        :error -> fallback
      end

    if action, do: {action, receiver_scope(runtime)}
  end

  @doc "Capture only receiving identity and its application metadata; omit AI state and caller context."
  def receiver_scope(runtime) do
    own = Aikido.Agent.resource_attributes(runtime.agent)

    context = %{
      aikido: %{
        agent_id: runtime.id,
        agent_resource: runtime.agent_module,
        aikido: runtime.aikido,
        partition: runtime.partition,
        metadata: Map.get(own, :metadata) || %{}
      }
    }

    Ash.Scope.to_opts(runtime.bound_execution_scope || %{}, context: context)
  end

  @doc "Run one native preparation action and enforce its transient result through the native typed contract."
  def prepare({resource, action}, model, options, scope) do
    with {:ok, prepared} <-
           resource
           |> Ash.ActionInput.for_action(action, %{model: model, options: options}, scope)
           |> Ash.run_action(scope),
         {:ok, request} <- Aikido.AiReact.Types.ModelRequest.new(prepared) do
      {:ok, request}
    else
      {:error, error} -> failure(resource, action, error)
      _unexpected -> failure(resource, action, nil)
    end
  rescue
    error -> failure(resource, action, error)
  catch
    kind, _reason -> failure(resource, action, kind)
  end

  defp failure(resource, action, cause) do
    type =
      case cause do
        %{__struct__: module} -> module
        kind when kind in [:exit, :throw, :error] -> kind
        _ -> :invalid_result
      end

    {:error,
     Aikido.AiReact.Errors.ModelPreparationFailed.exception(
       resource: resource,
       action: action,
       cause_type: type
     )}
  end
end
