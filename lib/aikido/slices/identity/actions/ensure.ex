defmodule Aikido.Slices.Identity.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Aikido.Slices.Identity.State{}` mounted at the `:identity`
  slice. Materializes a fresh `Aikido.Slices.Identity.State.new/1` when the slice is
  empty; otherwise no-op.
  """

  use Aikido.Action

  alias Aikido.Slices.Identity.State

  action do
    name "identity_ensure"
    description "Initialize identity state if missing."

    schema do
      attribute :profile, :map,
        description: "Initial profile map for new identities.",
        default: %{age: nil}
    end
  end

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %State{} = identity -> {:ok, identity, []}
      _ -> {:ok, State.new(Map.to_list(data)), []}
    end
  end
end
