defmodule Aikido.Ownership do
  @moduledoc """
  Live process ownership, independent of Team's desired topology and task ledger.

  Owned children are recorded by `Aikido.Ownership.Slice` through lifecycle
  signals. Team may start, adopt, retire or replace workers; Ownership records
  which processes are currently attached. Child references and monitors are
  transient and are rebuilt from child startup announcements after activation.
  """

  @doc "Read the mounted ownership slice's live children from an agent runtime."
  def children(%{agent: %{state: state}}) do
    Enum.find_value(state, %{}, fn
      {_, %Aikido.Ownership.Slice{children: children}} -> children
      _ -> nil
    end)
  end

  @doc "Read the current logical parent from the mounted ownership slice."
  def parent(runtime), do: binding(runtime, :parent)

  @doc "Read the former parent retained after an orphan transition."
  def orphaned_from(runtime), do: binding(runtime, :orphaned_from)

  @doc false
  def parent_monitor(runtime), do: binding(runtime, :parent_monitor)

  defp binding(%{agent: %{state: state}}, field) do
    Enum.find_value(state, fn
      {_, %Aikido.Ownership.Slice{} = slice} -> Map.fetch!(slice, field)
      _ -> nil
    end)
  end
end
