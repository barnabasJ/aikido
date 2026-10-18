defmodule Aikido.Actions.Lifecycle do
  @moduledoc """
  Base actions for agent lifecycle and coordination patterns.

  These actions provide common patterns for:
  - Parent-child communication
  - Process spawning
  - Graceful termination

  ## Usage

      use Aikido.Agent

      agent do
        name "coordinator_agent"
      end

      signal_routes do
        route "work.done", Aikido.Actions.Lifecycle.NotifyParent
        route "spawn.worker", Aikido.Actions.Lifecycle.SpawnChild
        route "shutdown", Aikido.Actions.Lifecycle.StopSelf
      end
  """
end
