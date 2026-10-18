defmodule Aikido.AgentServer.Actions.QueryChildren do
  @moduledoc """
  Routed to `aikido.agent.query.children`. Builds the reply via the
  `%Aikido.Directives.Reply{}` directive so the children map is read
  under directive execution with server state access.

  Reply shapes:

      aikido.agent.query.children.reply → %{children: %{tag => pid}}
      aikido.agent.query.children.error → %{reason: term}
  """

  use Aikido.Action

  action do
    name "agent_query_children"

    schema do
    end
  end

  alias Aikido.Signal.Call

  @impl true
  def run(signal, _slice, _opts, _ctx) do
    directive =
      Call.reply_from_state(
        signal,
        "aikido.agent.query.children.reply",
        "aikido.agent.query.children.error",
        {Aikido.AgentServer.Queries, :build_children_reply, []}
      )

    {:ok, %{}, List.wrap(directive)}
  end
end
