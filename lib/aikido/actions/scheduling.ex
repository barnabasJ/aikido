defmodule Aikido.Actions.Scheduling do
  @moduledoc """
  Base actions for scheduling delayed signals and timeouts.

  These actions wrap the `Schedule` directive for common timing patterns.

  ## Usage

      use Aikido.Agent

      agent do
        name "timed_worker"
      end

      signal_routes do
        route "work.start", MyStartAction       # Might schedule a timeout
        route "work.timeout", MyTimeoutHandler
      end
  """
end
