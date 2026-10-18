defmodule Aikido.Config do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, input.arguments}
end
