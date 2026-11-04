defmodule Aikido.AiWorker.Errors.RequestRejected do
  @moduledoc "Public AI admission failure without native action subjects or request content."
  use Splode.Error, fields: [:failure], class: :invalid

  def message(%{failure: :forbidden}) do
    "The receiving worker did not authorize its AI request. Restore its own model permission before assigning this work again; no matching AI run was adopted."
  end

  def message(%{failure: :invalid}) do
    "The receiving worker rejected its AI request input. Check its model configuration and task payload before assigning this work again; no matching AI run was adopted."
  end

  def message(_error) do
    "The receiving worker could not admit its AI request. Inspect its runtime diagnostics before assigning this work again; no matching AI run was adopted."
  end
end

defimpl AshAi.ToToolError, for: Aikido.AiWorker.Errors.RequestRejected do
  def to_tool_error(error), do: Aikido.AiWorker.Errors.RequestRejected.message(error)
end

defimpl AshLua.Error, for: Aikido.AiWorker.Errors.RequestRejected do
  def to_error(error) do
    %{
      message: Aikido.AiWorker.Errors.RequestRejected.message(error),
      short_message: "Worker AI request rejected",
      code: "worker_ai_request_rejected",
      fields: [],
      vars: %{failure: error.failure}
    }
  end
end
