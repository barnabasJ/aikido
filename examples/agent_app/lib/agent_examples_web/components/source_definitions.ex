defmodule AgentExamplesWeb.Components.SourceDefinitions do
  @moduledoc "Reusable source definitions display for example pages."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [highlighted_code: 1]
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> attach_hook(:source_definitions_commands, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("toggle_definition", %{"id" => id}, socket) do
    definitions =
      Enum.map(socket.assigns.definitions, fn definition ->
        if definition.id == id, do: %{definition | open?: !definition.open?}, else: definition
      end)

    {:halt, assign(socket, :definitions, definitions)}
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  attr :definitions, :list, required: true

  def source_definitions(assigns) do
    ~H"""
    <section class="definitions" id="definitions" aria-label="Example source definitions">
      <.section_heading>
        <:title>Code definitions</:title>
        <span>Agents and slices open by default · each module opens independently</span>
      </.section_heading>
      <.source_definition :for={definition <- @definitions} definition={definition} />
    </section>
    """
  end

  attr :definition, :map, required: true

  def source_definition(assigns) do
    ~H"""
    <details
      id={@definition.id}
      open={@definition.open?}
      class="code-definition"
      data-kind={@definition.category}
    >
      <summary phx-click="toggle_definition" phx-value-id={@definition.id}>
        <span class="definition-name">{@definition.name}</span><span class="definition-path">{@definition.path}</span>
      </summary>
      <.highlighted_code
        :if={@definition.open?}
        text={@definition.code}
        lexer={Makeup.Lexers.ElixirLexer}
      />
    </details>
    """
  end
end
