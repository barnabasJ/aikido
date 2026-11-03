defmodule Aikido.Thread.Types.Channel do
  @moduledoc "The owning native journal whose follow and acknowledgement routes are used."
  use Ash.Type.Enum, values: [:thread, :roster]
end
