defmodule Aikido.Team.Types.DeliveryKind do
  @moduledoc "Trusted team delivery boundaries using the recipient's activation identity."
  use Ash.Type.Enum,
    values: [
      :task,
      :completion,
      :result,
      :cancel,
      :message,
      :inheritance,
      :inheritance_result,
      :stop,
      :stop_cleanup,
      :stop_result,
      :stop_cleanup_result,
      :owned_child_exit,
      :stop_monitor
    ]
end
