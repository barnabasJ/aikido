defmodule Aikido.Agent.Errors.StartupCleanupFailed do
  @moduledoc "A topology startup failure whose subsequent scoped cleanup also failed."
  use Splode.Error, class: :invalid, fields: [:agent_id, :startup, :cleanup]

  def message(error) do
    "Agent #{inspect(error.agent_id)} could not start its initial topology, and cleanup " <>
      "also failed. It may still be running. Inspect it, then retry stop with authority " <>
      "that permits cleanup."
  end
end

defimpl AshAi.ToToolError, for: Aikido.Agent.Errors.StartupCleanupFailed do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Agent.Errors.StartupCleanupFailed do
  def to_error(error) do
    %{
      code: "startup_cleanup_failed",
      message: Exception.message(error),
      short_message: "Startup cleanup failed",
      fields: [],
      vars: %{agent_id: error.agent_id}
    }
  end
end
