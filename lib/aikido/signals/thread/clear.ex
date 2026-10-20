defmodule Aikido.Signals.Thread.Clear do
  @moduledoc "Typed payload for `aikido.thread.clear`."
  use Aikido.Signal

  signal do
    type "aikido.thread.clear"
  end
end
