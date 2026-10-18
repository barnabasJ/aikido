defmodule Aikido.Slices.Identity.Actions.UpdateProfile do
  @moduledoc """
  Merges a partial profile map into the identity, bumping the revision.
  Materializes the slice via `Aikido.Slices.Identity.State.new/0` when it has not been
  initialized yet.
  """

  use Aikido.Action

  alias Aikido.Slices.Identity.State

  action do
    name "identity_update_profile"
    description "Merge a partial profile map into the identity profile."

    schema do
      attribute :profile, :map,
        description: "Partial profile map to merge into the identity.",
        allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{profile: profile}}, slice, _opts, _ctx) do
    identity = ensure_identity(slice)
    {:ok, State.update_profile(identity, profile), []}
  end

  defp ensure_identity(%State{} = identity) do
    identity
  end

  defp ensure_identity(_) do
    State.new()
  end
end
