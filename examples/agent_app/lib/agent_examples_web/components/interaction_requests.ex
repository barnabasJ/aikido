defmodule AgentExamplesWeb.Components.InteractionRequests do
  @moduledoc "Reusable interaction choices with server-side request validation."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [inspected_value: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :interaction_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("respond", %{"id" => id, "choice" => choice}, socket) do
    requests =
      if socket.assigns.run,
        do: socket.assigns.run.requests,
        else: []

    request = Enum.find(requests, &(&1.id == id))

    if request && choice in Map.get(request.payload, "choices", []) do
      ExamplePage.command(socket, :respond, %{interaction_id: id, response: %{choice: choice}})
    else
      {:halt, assign(socket, error: "This request is no longer available.")}
    end
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def interaction_requests(assigns) do
    ~H"""
    <section :if={active?(@run)} id="hook-requests">
      <.interaction_request :for={request <- @run.requests} request={request} />
    </section>
    """
  end

  attr :request, :map, required: true

  def interaction_request(assigns) do
    ~H"""
    <article
      id={"request-#{@request.id}"}
      class="panel"
    >
      <h3>{Map.get(@request.payload, "title", @request.type)}</h3>
      <.inspected_value value={Map.get(@request.payload, "details", @request.payload)} />
      <div class="inline-form">
        <button
          :for={choice <- Map.get(@request.payload, "choices", [])}
          class="button secondary"
          phx-click="respond"
          phx-value-id={@request.id}
          phx-value-choice={choice}
        >{choice}</button>
        <button class="button danger" phx-click="cancel_run">Cancel run</button>
      </div>
    </article>
    """
  end
end
