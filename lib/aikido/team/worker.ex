defmodule Aikido.Team.Worker do
  @moduledoc "A reusable template for dynamically added team members."
  defstruct [
    :name,
    :resource,
    max_members: 8,
    initial_state: %{},
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
