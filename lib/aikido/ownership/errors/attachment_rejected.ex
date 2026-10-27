defmodule Aikido.Ownership.Errors.AttachmentRejected do
  @moduledoc "A logical parent attachment conflicts with the agent's current ownership."
  use Splode.Error, class: :invalid, fields: [:reason, :parent_id, :current_parent_id]

  def message(%{reason: :already_attached} = error) do
    "Cannot attach parent #{inspect(error.parent_id)}: the agent is already attached to " <>
      "#{inspect(error.current_parent_id)}. Reuse the existing relationship; " <>
      "reattach only after the previous parent has exited and the agent has become orphaned."
  end

  def message(error) do
    "Cannot attach parent #{inspect(error.parent_id)}: the parent reference must contain " <>
      "a process PID different from the child. Resolve the intended parent's current " <>
      "agent reference before retrying."
  end
end

defimpl AshAi.ToToolError, for: Aikido.Ownership.Errors.AttachmentRejected do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Ownership.Errors.AttachmentRejected do
  def to_error(error) do
    %{
      code: "parent_attachment_rejected",
      message: Exception.message(error),
      short_message: "Parent attachment rejected",
      fields: [],
      vars: %{reason: error.reason, parent_id: error.parent_id}
    }
  end
end
