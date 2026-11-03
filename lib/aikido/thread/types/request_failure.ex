defmodule Aikido.Thread.Types.RequestFailure do
  @moduledoc "Native failure class returned without private source state or actor data."
  use Ash.Type.Enum, values: [:forbidden, :invalid, :unknown]
end
