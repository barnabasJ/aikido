defmodule AgentExamplesWeb.Components.ExampleHeader do
  @moduledoc "Reusable example header display for example pages."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [status_pill: 1]
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]
  attr :example, :map, required: true
  attr :run, :any, required: true
  attr :starting, :boolean, required: true

  def example_header(assigns) do
    ~H"""
    <header class="example-header">
      <.link navigate="/" class="back-link">← All examples</.link>
      <div class="eyebrow">{@example.eyebrow}</div>
      <div class="title-row">
        <h1>{@example.title}</h1><.status_pill active={active?(@run)}>
          {if @starting,
            do: "Starting…",
            else: if(@run, do: to_string(@run.status), else: "Not started")}
        </.status_pill>
      </div>
      <p>{@example.description}</p>
    </header>
    """
  end
end
