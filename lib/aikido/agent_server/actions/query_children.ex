defmodule Aikido.AgentServer.Actions.QueryChildren do
  @moduledoc "Routed to `aikido.agent.query.children`. Builds the reply via the\n`%Aikido.Directives.Reply{}` directive so the children map is read\nunder directive execution with server state access.\n\nReply shapes:\n\n    aikido.agent.query.children.reply → %{children: %{tag => pid}}\n    aikido.agent.query.children.error → %{reason: term}\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "agent_query_children"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  alias Aikido.Signal.Call

  defp reduce(signal, _slice, _opts, _ctx) do
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
