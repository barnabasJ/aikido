defmodule Aikido.AgentServer.SignalRouter do
  @moduledoc """
  Builds a unified Aikido.Signal.Router from agent and slice routes.

  This module is responsible for:
  1. Collecting routes from all sources (agent, slices)
  2. Normalizing route specs with appropriate priorities
  3. Building the trie-based router for efficient signal routing

  ## Priority Levels

  | Source | Default Priority | Range     |
  |--------|------------------|-----------|
  | Agent  | 0                | -25 to 25 |
  | Slice  | -10              | -50 to -10|

  ## Route Spec Formats

  Routes can be specified in several formats:
  - `{path, target}` - Simple route with default priority
  - `{path, target, priority}` - Route with explicit priority
  - `{path, match_fn, target}` - Route with match function
  - `{path, match_fn, target, priority}` - Route with match function and priority

  ## Target Types

  - `{resource, action}` - Native generic Ash action; signal data supplies its arguments
  """

  alias Aikido.AgentServer.State
  alias Aikido.Signal.Router

  @agent_default_priority 0
  @slice_default_priority -10

  @doc """
  Builds a unified router from all route sources in the agent state.

  Collects routes from:
  - Agent routes (priority 0) via `Aikido.Agent.Info.signal_routes/1`
  - Slice routes (priority -10) via the compiled slice route table

  Native router validation rejects invalid routes instead of silently dropping them.
  """
  @spec build(State.t()) :: Router.t()
  def build(%State{} = state) do
    routes =
      []
      |> add_agent_routes(state)
      |> add_slice_routes(state)
      |> add_builtin_routes()

    Router.new!(routes)
  end

  # Built-in system routes available on every agent. Priority sits below
  # slice/agent so user-defined routes always win on conflict.
  defp add_builtin_routes(routes) do
    builtin = [
      {"aikido.agent.query.children", {Aikido.AgentServer.RuntimeActions, :query_children}}
    ]

    routes ++ normalize_routes(builtin, @slice_default_priority - 10)
  end

  defp add_agent_routes(routes, %State{agent_module: agent_module}) do
    agent_routes = Aikido.Agent.Info.signal_routes(agent_module)
    routes ++ normalize_routes(agent_routes, @agent_default_priority)
  end

  # Collects routes from slices via the agent's pre-expanded `routes/1`
  # table — the slice's declared routes are the
  # single source of truth for slice routes. Already normalized with
  # priority by the agent transformer pipeline.
  defp add_slice_routes(routes, %State{agent_module: agent_module}) do
    routes ++ Aikido.Agent.Info.routes(agent_module)
  end

  defp normalize_routes(routes, default_priority) do
    Enum.map(routes, fn
      {path, target, priority} when is_integer(priority) ->
        {path, target, priority}

      {path, match_fn, target, priority} when is_function(match_fn, 1) and is_integer(priority) ->
        {path, match_fn, target, priority}

      {path, match_fn, target} when is_function(match_fn, 1) ->
        {path, match_fn, target, default_priority}

      {path, target} ->
        {path, target, default_priority}
    end)
  end
end
