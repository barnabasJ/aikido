defmodule Aikido.Agent.ExecutionIdentity do
  @moduledoc "Compares authenticated activation authority using its actor and tenant."

  @doc "Whether a binding exists and matches the supplied native caller scope."
  def matches?(nil, _scope), do: false

  def matches?(binding, scope) do
    Map.get(binding, :actor) == Map.get(scope, :actor) &&
      Map.get(binding, :tenant) == Map.get(scope, :tenant)
  end
end
