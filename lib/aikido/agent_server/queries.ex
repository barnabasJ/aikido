defmodule Aikido.AgentServer.Queries do
  @moduledoc """
  Reply builders for agent-level introspection queries.

  Invoked by the `%Aikido.Directives.Reply{}` executor with full
  `%Aikido.AgentServer.State{}` access for signals universal to every agent.

  Each function returns `{:ok, map}` on success and `{:error, term}` on
  failure; the directive maps those to `<query>.reply` and `<query>.error`
  signals respectively.
  """

  alias Aikido.AgentServer.ChildInfo
  alias Aikido.AgentServer.State

  @doc """
  Builder for `aikido.agent.query.children`. Returns `{:ok, %{children: %{tag => pid}}}`.
  """
  @spec build_children_reply(State.t()) :: {:ok, map()}
  def build_children_reply(%State{children: children}) when is_map(children) do
    pids =
      Map.new(children, fn {tag, %ChildInfo{pid: pid}} -> {tag, pid} end)

    {:ok, %{children: pids}}
  end
end
