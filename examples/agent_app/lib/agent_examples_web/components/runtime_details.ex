defmodule AgentExamplesWeb.Components.RuntimeDetails do
  @moduledoc "Reusable runtime details display for example pages."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [inspected_value: 1]
  import AgentExamplesWeb.Components.UI, only: [section_heading: 1]
  alias AgentExamples.Catalog
  import AgentExamplesWeb.ExampleComponents, only: [active?: 1]
  attr :example, :map, required: true
  attr :run, :any, required: true

  def runtime_details(assigns) do
    ~H"""
    <section class="panel">
      <.section_heading>
        <:title>Under the hood</:title>
        <span class="live-dot"></span>
      </.section_heading><dl>
        <dt>Runtime</dt><dd>Aikido.Default</dd><dt>
          Instance
        </dt><dd class="instance-id">{if @run, do: @run.record.id, else: "Not started"}</dd><dt :if={
          Catalog.ai?(@example)
        }>
          Model turns
        </dt><dd :if={Catalog.ai?(@example)}>
          {if @run, do: Map.get(@run.snapshot.ai, :iteration, 0), else: 0}
        </dd>
        <dt :if={Catalog.ai?(@example) && @run}>Model in this agent</dt>
        <dd :if={Catalog.ai?(@example) && @run} id="active-model">
          {Map.get(@run.snapshot.ai, :model_label, "Not configured")}
        </dd>
      </dl>
      <details :if={@run && !@run.snapshot.team?} id="agent-state" class="agent-state">
        <summary>View current agent state</summary>
        <p class="muted">
          {inspect(@run.snapshot.resource)} · updates as signals are processed{if @run.status ==
                                                                                    :stopped,
                                                                                  do:
                                                                                    " · last recorded state"}
        </p>
        <.inspected_value value={display_state(@run.snapshot)} limit={:infinity} />
      </details>
      <p :if={@run && @run.snapshot.team?} class="muted">
        Select an agent in the team tree to inspect its state and activity.
      </p>
      <button :if={active?(@run)} id="stop-example" phx-click="stop" class="button danger">Stop example</button>
    </section>
    """
  end

  defp display_state(snapshot) do
    %{state: snapshot.own}
    |> include_slice(:ai, if(snapshot.activity, do: snapshot.ai, else: %{}))
    |> include_slice(:todos, snapshot.todos)
    |> include_slice(:journal, snapshot.journal)
  end

  defp include_slice(state, _name, value) when value in [%{}, []], do: state
  defp include_slice(state, name, value), do: Map.put(state, name, value)
end
