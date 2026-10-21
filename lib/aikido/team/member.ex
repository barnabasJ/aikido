defmodule Aikido.Team.Member do
  @moduledoc "A predefined member in a team topology."
  defstruct [
    :name,
    :resource,
    :owner,
    initial_state: %{},
    activation: :eager,
    depends_on: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
