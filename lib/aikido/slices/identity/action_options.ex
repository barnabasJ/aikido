defmodule Aikido.Slices.Identity.ActionOptions do
  @moduledoc false

  def from_input(input) do
    [now: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))]
  end
end
