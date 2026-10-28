defmodule AgentExamples.NotificationCounter.Observer.Scope do
  @moduledoc "Receiving scope for this deliberately public, local counter example."

  def resolve(_agent), do: {:ok, %{authorize?: true}}
end
