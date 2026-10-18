defmodule AgentExamplesWeb.IndexLive do
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.Components

  def mount(_, _, socket), do: {:ok, assign(socket, :examples, AgentExamples.Catalog.all())}

  def render(assigns) do
    ~H"""
    <.shell>
      <header class="hero">
        <div class="eyebrow">THE AGENT LAB</div>
        <h1>Small examples.<br /><span>Real possibilities.</span></h1>
        <p>
          Explore agents one signal at a time. Change state, compose slices, dispatch work, and watch a team build itself.
        </p>
        <div class="hero-pills">
          <span>9 interactive examples</span><span>Offline AI included</span><span>No database required</span>
        </div>
      </header>
      <div class="section-heading">
        <h2>Choose an experiment</h2><span>From a counter to an orchestrated team</span>
      </div>
      <section class="example-grid">
        <.link
          :for={{example, index} <- Enum.with_index(@examples)}
          navigate={"/examples/#{example.slug}"}
          class="example-card"
          id={"example-#{example.slug}"}
        >
          <div class="card-top">
            <span class="card-number">0{index + 1}</span><span class="card-arrow">↗</span>
          </div>
          <div class="eyebrow">{example.eyebrow}</div>
          <h2>{example.title}</h2>
          <p>{example.description}</p>
          <div class="mini-flow"><span :for={step <- Enum.take(example.flow, 3)}>{step}</span></div>
          <span class="card-cta">Open example →</span>
        </.link>
      </section>
      <footer class="page-footer">
        Built with Ash resources, Aikido agents, and Phoenix LiveView.
      </footer>
    </.shell>
    """
  end
end
