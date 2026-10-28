defmodule Aikido.Durable.ScopeAdapter.Error do
  @moduledoc "Authentication failure at a durable scope boundary."
  defexception [:operation, :reason]

  @impl true
  def message(%{operation: operation, reason: reason}) when is_atom(reason),
    do: "Durable scope #{operation} rejected: #{reason}"

  def message(error), do: "Durable scope #{error.operation} rejected"
end
