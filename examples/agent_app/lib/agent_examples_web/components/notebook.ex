defmodule AgentExamplesWeb.Components.Notebook do
  @moduledoc "Reusable notebook controls and their LiveView mount hook."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1, message: 1]
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :notebook_commands, :handle_event, &handle_event/3)}
  end

  defp handle_event("append", %{"text" => text}, socket),
    do: ExamplePage.command(socket, :append, %{text: text})

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :run, :any, required: true

  def notebook(assigns) do
    ~H"""
    <section class="panel">
      <.section_heading>
        <:title>{own(@run)[:title] || "Notebook"}</:title>
        <span>Embedded journal slice</span>
      </.section_heading>
      <div id="journal" class="journal">
        <.message
          :for={{entry, index} <- Enum.with_index(if(@run, do: @run.snapshot.journal, else: []))}
          label={"NOTE #{index + 1}"}
          text={entry}
          format={:paragraph}
        />
      </div>
      <form id="notebook-form" phx-submit="append">
        <label>Journal entry<textarea
          name="text"
          rows="3"
          placeholder="What did you discover?"
          required
        ></textarea></label><button class="button primary" disabled={!active?(@run)}>Append note →</button>
      </form>
    </section>
    """
  end
end
