defmodule Aikido.Durable.ScopeAdapter.Error do
  @moduledoc """
  Authentication failure at a durable scope boundary.

  Applications may attach public `:denial_facts`, `:request_id`, and
  `:request_ids` to `vars`. Native startup applies Ash constraints: 65,536
  bytes of rendered facts, 256 bytes per request ID, and at most 64 IDs.
  Nonempty rendered facts are appended to the base message.

  To expose structured `vars[:denial]`, supply `denial_type: MyApp.PublicDenial`,
  an application-owned Ash type with a constrained public schema and bounds.
  Native startup casts that value through the supplied type; without a type,
  structured denial is omitted. Other vars and the type configuration are
  excluded from the rebuilt public error. Invalid public values omit all vars
  while preserving the typed refusal. These diagnostics never grant authority.
  """
  use Splode.Error, class: :forbidden, fields: [:operation, :reason, :denial_type]

  @public_fields [
    denial_facts: [
      type: :string,
      constraints: [max_length: 65_536, length_count: :bytes, trim?: false, allow_empty?: true]
    ],
    request_id: [
      type: :string,
      constraints: [max_length: 256, length_count: :bytes, trim?: false]
    ],
    request_ids: [
      type: {:array, :string},
      constraints: [
        max_length: 64,
        items: [min_length: 1, max_length: 256, length_count: :bytes, trim?: false]
      ]
    ]
  ]

  @doc "Project native public refusal vars through SDK and application-owned Ash types."
  def public_vars(error) do
    fields =
      if error.denial_type,
        do: @public_fields ++ [denial: [type: error.denial_type]],
        else: @public_fields

    with {:ok, constraints} <- Ash.Type.init(:keyword, fields: fields),
         {:ok, vars} <- Ash.Type.cast_input(:keyword, error.vars || [], constraints),
         {:ok, vars} <- Ash.Type.apply_constraints(:keyword, vars, constraints) do
      vars
    else
      _ -> []
    end
  end

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
