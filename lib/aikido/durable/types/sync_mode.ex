defmodule Aikido.Durable.Types.SyncMode do
  @moduledoc "Periodic checkpoints, native automatic sync, or strict explicit sync on persistent transitions."
  use Ash.Type.Enum, values: [:periodic, :automatic, :explicit]
end
