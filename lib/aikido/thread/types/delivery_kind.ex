defmodule Aikido.Thread.Types.DeliveryKind do
  @moduledoc "Whether journal delivery retains consumer request authority or binds the batch recipient."
  use Ash.Type.Enum, values: [:request, :batch]
end
