defmodule Aikido.Thread.Types.DeliveryKind do
  @moduledoc "Journal request, source reply or consumer-owned SQL-work delivery."
  use Ash.Type.Enum, values: [:request, :batch, :work]
end
