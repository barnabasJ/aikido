defmodule Aikido.Thread.Consumer.Types.CreditPhase do
  @moduledoc "Fixed native journal protocol states."
  use Ash.Type.Enum, values: [:requesting, :writing]
end
