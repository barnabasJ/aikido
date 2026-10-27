defmodule AgentExamplesWeb.Components.VerifiedWork do
  @moduledoc "Reusable verified work panel and command mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [todo_item: 1]
  import Phoenix.LiveView
  alias AgentExamplesWeb.ExamplePage
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]
  import AgentExamplesWeb.Markdown

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :verified_work_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("deliver", _, socket),
    do:
      ExamplePage.command(socket, :deliver, %{
        text: "Complete delivered-work with evidence",
        request_id: Ash.UUIDv7.generate(),
        todo: %{id: "delivered-work", text: "Check the delivered task", blocking?: true}
      })

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def verified_work(assigns) do
    ~H"""
    <section :if={active?(@run)} class="panel" id="verified-work">
      <h2>Work and evidence</h2>
      <button id="deliver-work" class="button primary" phx-click="deliver">Deliver task + todo</button>
      <button class="button danger" phx-click="cancel_run">Cancel</button>
      <p>
        Continuations: {Map.get(@run.snapshot.ai, :todo_continuations, 0)} · Verifying: {Map.get(
          @run.snapshot.ai,
          :todo_verification_pending,
          false
        )}
      </p>
      <.todo_item :for={item <- @run.snapshot.todos} item={item} show_result />
      <div id="verified-answer"><.markdown text={Map.get(@run.snapshot.ai, :result)} /></div>
    </section>
    """
  end
end
