defmodule Aikido.Thread.Types.GapReason do
  @moduledoc "Why a requested journal position cannot be replayed truthfully."
  use Ash.Type.Enum, values: [:generation_changed, :pruned, :ahead]
end
