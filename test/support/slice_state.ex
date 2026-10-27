defmodule AikidoTest.SliceState do
  @moduledoc "Build a reducer scenario through its embedded resource's create action."

  def new(resource, overrides \\ %{}) do
    Ash.create!(resource, overrides, action: :create)
  end

  @doc "Return declared state attributes, excluding Ash's internal selection metadata."
  def attributes(%resource{} = state) do
    names = Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)
    Map.take(state, names)
  end
end
