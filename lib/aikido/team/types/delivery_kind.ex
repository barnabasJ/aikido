defmodule Aikido.Team.Types.DeliveryKind do
  @moduledoc "Trusted team delivery boundaries using the recipient's activation identity."
  use Ash.Type.Enum,
    values: [:task, :completion, :result, :cancel, :message]
end
