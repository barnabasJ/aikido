defmodule Aikido.Ownership.Signals.QueryChildren do
  @moduledoc "Requests the live child roster through the signal's reply destination."
  use Aikido.Signal

  signal do
    type "aikido.agent.query.children"
  end
end
