defmodule Aikido.AiReact.Errors.ModelPreparationFailed do
  @moduledoc "Finite model preparation failure without raw action input, options or provider credentials."
  use Splode.Error, fields: [:resource, :action, :cause_type], class: :invalid

  def message(error) do
    "Model preparation #{inspect(error.resource)}.#{error.action} failed under the receiving agent's authority (#{inspect(error.cause_type)}). #{recovery(error)} No model generation call was made for this attempt."
  end

  defp recovery(%{cause_type: Ash.Error.Forbidden}),
    do: "Check the receiving actor's provider permission and credential access."

  defp recovery(%{cause_type: Ash.Error.Invalid}),
    do:
      "Check the preparation action's model/options contract and the receiving agent's metadata."

  defp recovery(_error),
    do:
      "Inspect the preparation action and its current provider configuration without sharing credentials."
end

defimpl AshAi.ToToolError, for: Aikido.AiReact.Errors.ModelPreparationFailed do
  def to_tool_error(error), do: Aikido.AiReact.Errors.ModelPreparationFailed.message(error)
end

defimpl AshLua.Error, for: Aikido.AiReact.Errors.ModelPreparationFailed do
  def to_error(error) do
    %{
      message: Aikido.AiReact.Errors.ModelPreparationFailed.message(error),
      short_message: "Model preparation failed",
      code: "model_preparation_failed",
      fields: [],
      vars: %{resource: error.resource, action: error.action, cause_type: error.cause_type}
    }
  end
end
