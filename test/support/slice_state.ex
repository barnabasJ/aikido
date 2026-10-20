defmodule AikidoTest.SliceState do
  @moduledoc "Build native embedded state before overlaying a reducer test's scenario."

  def new(resource, overrides \\ %{}) do
    {:ok, state} =
      resource
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.Changeset.apply_attributes()

    Map.merge(state, overrides)
  end
end
