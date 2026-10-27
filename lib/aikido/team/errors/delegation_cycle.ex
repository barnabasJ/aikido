defmodule Aikido.Team.Errors.DelegationCycle do
  @moduledoc "A foreground delegation would make workers wait on each other."
  use Splode.Error, fields: [:members], class: :invalid

  def message(error) do
    chain = Enum.map_join(error.members, " -> ", &to_string/1)

    "Delegation would create a circular wait: #{chain}. " <>
      "Complete the task directly, choose another worker, or use background mode and continue without waiting."
  end
end

defimpl AshAi.ToToolError, for: Aikido.Team.Errors.DelegationCycle do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Team.Errors.DelegationCycle do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Circular delegation",
      code: "delegation_cycle",
      fields: [],
      vars: %{}
    }
  end
end
