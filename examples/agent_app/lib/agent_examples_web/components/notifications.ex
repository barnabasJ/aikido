defmodule AgentExamplesWeb.Components.Notifications do
  @moduledoc "Reusable controls for the native publication example."
  use Phoenix.Component
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1, own: 1]
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :notification_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("publish_increment", _params, socket),
    do: AgentExamplesWeb.ExamplePage.command(socket, :increment, %{})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def notifications(assigns) do
    ~H"""
    <section class="panel" id="notifications-demo">
      <.section_heading>
        <:title>Native publications</:title>
        <span>Publisher → Ash PubSub → observer</span>
      </.section_heading>
      <p>The publisher exposes only its count calculation. The child subscribes during startup,
        adopts the typed value, and sends an acknowledgement through a normal signal.</p>
      <dl>
        <dt>Publisher count</dt><dd id="published-count">{own(@run)[:count] || 0}</dd>
        <dt>Observer acknowledgement</dt><dd id="observed-count">
          {own(@run)[:result] || "Waiting for observer"}
        </dd>
      </dl>
      <button
        id="publish-increment"
        class="button primary"
        phx-click="publish_increment"
        disabled={!active?(@run) || !own(@run)[:enabled]}
      >Increment and publish</button>
      <p class="muted">This counter is public. A topic routes messages; application policies and
        authorized topic access must protect private data. PubSub does not replay missed events.</p>
    </section>
    """
  end
end
