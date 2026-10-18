defmodule Aikido.Actions.Control do
  @moduledoc """
  Base actions for control flow and signal handling.

  These actions provide common patterns for:
  - Cancellation handling
  - Signal forwarding
  - No-op acknowledgment

  ## Usage

      use Aikido.Agent

      agent do
        name "my_agent"
      end

      signal_routes do
        route "aikido.agent.cancel", Aikido.Actions.Control.Cancel
        route "proxy.forward", Aikido.Actions.Control.Forward
      end
  """
end
