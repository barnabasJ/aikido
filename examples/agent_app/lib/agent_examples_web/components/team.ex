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

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true
  attr :team_trees, :map, default: %{}

  def team(assigns) do
    ~H"""
    <.team_topology tree_states={@team_trees} run={@run}>
      <button id="team-add" phx-click="team_add" class="button secondary" disabled={!active?(@run)}>Send +1 to the counter</button>
    </.team_topology>
    """
  end
end
