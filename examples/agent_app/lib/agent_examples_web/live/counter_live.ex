defmodule AgentExamplesWeb.CounterLive do
  @moduledoc "Interactive counter example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Counter, only: [counter: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "counter"})
  on_mount({AgentExamplesWeb.Components.Counter, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.counter run={@run} />
    </.page>
    """
  end
end
