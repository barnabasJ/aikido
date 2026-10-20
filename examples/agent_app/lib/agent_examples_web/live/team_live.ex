defmodule AgentExamplesWeb.TeamLive do
  @moduledoc "Interactive team example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "team"})

  def handle_event("team_add", _, socket),
    do:
      ExamplePage.command(socket, :send, %{
        member: :counter,
        type: "counter.add",
        payload: %{amount: 1}
      })

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.team_topology run={@run}>
        <button id="team-add" phx-click="team_add" class="button secondary" disabled={!active?(@run)}>Send +1 to the counter</button>
      </.team_topology>
    </.page>
    """
  end
end
