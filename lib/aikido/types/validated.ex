defmodule Aikido.Types.Validated do
  @moduledoc "Ash type for a value with a named domain validation."
  use Ash.Type
  def storage_type(_), do: :term

  def matches_type?(value, constraints),
    do: Ash.Type.matches_type?(constraints[:type], value, constraints[:constraints] || [])

  def constraints,
    do: [
      type: [type: :any, required: true],
      constraints: [type: :keyword_list, default: []],
      validation: [type: :mfa, required: true]
    ]

  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) do
    type = constraints[:type]

    with {:ok, type_constraints} <- Ash.Type.init(type, constraints[:constraints]),
         {:ok, value} <- Ash.Type.cast_input(type, value, type_constraints),
         {:ok, value} <- Ash.Type.apply_constraints(type, value, type_constraints),
         {module, function, args} <- constraints[:validation] do
      # TypedStruct checks defaults while its host module is still compiling.
      # Self-hosted validators run when the completed type is cast at runtime.
      result = if Module.open?(module), do: :ok, else: apply(module, function, [value, [] | args])

      case result do
        :ok -> {:ok, value}
        {:ok, _} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def cast_stored(value, constraints), do: cast_input(value, constraints)
  def dump_to_native(value, _), do: {:ok, value}
end
