defmodule Aikido.Durable.ScopeAdapter.Error do
  @moduledoc """
  Authentication failure at a durable scope boundary.

  Applications may attach a bounded, already-rendered `:denial_facts` string
  (and a `:request_id`) to `vars`: Splode defines `vars` as the message
  rendering surface, so `message/1` appends those facts when present. The
  native start boundary preserves exactly these two whitelisted vars across
  its sanitization rebuild (`Aikido.Agent.Commands.Start.public_scope_refusal/1`);
  every other var is dropped there. Absent facts render the historical
  message unchanged.
  """
  use Splode.Error, class: :forbidden, fields: [:operation, :reason]

  @impl true
  def message(%{operation: operation, reason: reason} = error) when is_atom(reason) do
    base = "Durable scope #{operation} rejected: #{reason}"
    append_facts(base, Map.get(error, :vars) || [])
  end

  def message(error), do: "Durable scope #{error.operation} rejected"

  defp append_facts(base, vars) do
    case Keyword.get(vars, :denial_facts) do
      facts when is_binary(facts) and facts != "" -> base <> " " <> facts
      _absent -> base
    end
  end
end
