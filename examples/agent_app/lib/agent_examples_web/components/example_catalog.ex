defmodule AgentExamplesWeb.Components.ExampleCatalog do
  @moduledoc "Catalogue of interactive examples and reusable example cards."
  use Phoenix.Component
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]

  attr :examples, :list, default: AgentExamples.Catalog.all()

  def example_catalog(assigns) do
    ~H"""
    <header class="hero">
      <div class="eyebrow">THE AGENT LAB</div>
      <h1>Small examples.<br /><span>Real possibilities.</span></h1>
      <p>
        Explore agents one signal at a time. Change state, compose slices, dispatch work, and watch a team build itself.
      </p>
      <div class="hero-pills">
        <span>{length(@examples)} interactive examples</span><span>Offline AI included</span><span>No database required</span>
      </div>
    </header>
    <.section_heading>
      <:title>Choose an experiment</:title>
      <span>From a counter to an orchestrated team</span>
    </.section_heading>
    <section class="example-grid">
      <.example_card
        :for={{example, index} <- Enum.with_index(@examples)}
        example={example}
        index={index}
      />
    </section>
    <footer class="page-footer">
      Built with Ash resources, Aikido agents, and Phoenix LiveView.
    </footer>
    """
  end

  attr :example, :map, required: true
  attr :index, :integer, default: 0

  def example_card(assigns) do
    ~H"""
    <.link
      navigate={"/examples/#{@example.slug}"}
      class="example-card"
      id={"example-#{@example.slug}"}
    >
      <div class="card-top">
        <span class="card-number">0{@index + 1}</span><span class="card-arrow">↗</span>
      </div>
      <div class="eyebrow">{@example.eyebrow}</div>
      <h2>{@example.title}</h2>
      <p>{@example.description}</p>
      <div class="mini-flow"><span :for={step <- Enum.take(@example.flow, 3)}>{step}</span></div>
      <span class="card-cta">Open example →</span>
    </.link>
    """
  end
end
