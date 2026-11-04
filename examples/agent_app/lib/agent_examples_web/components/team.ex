defmodule AgentExamplesWeb.Components.Team do
  @moduledoc "Reusable team controls and command hook."
  use Phoenix.Component
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :team_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("team_add", _, socket),
    do:
      ExamplePage.command(socket, :send, %{
        member: :counter,
        type: "counter.add",
        payload: %{amount: 1}
      })

  defp handle_event("team_message", _, socket),
    do:
      ExamplePage.command(socket, :send, %{
        member: :self,
        requester: :counter,
        type: "example.team.message",
        payload: %{text: "Hello from the Team controls"}
      })

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true
  attr :team_trees, :map, default: %{}

  def team(assigns) do
    ~H"""
    <.team_topology tree_states={@team_trees} run={@run}>
      <button id="team-message" phx-click="team_message" class="button secondary" disabled={!active?(@run)}>Send as counter to coordinator</button>
      <p :if={@run && own(@run)[:last_message]} id="team-last-message">
        Requested by {own(@run)[:last_requester]}: {own(@run)[:last_message]}
      </p>
      <button id="team-add" phx-click="team_add" class="button secondary" disabled={!active?(@run)}>Send +1 to the counter</button>
    </.team_topology>
    """
  end
end
