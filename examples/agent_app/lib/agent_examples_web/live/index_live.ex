defmodule AgentExamplesWeb.IndexLive do
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.Components
  import AgentExamplesWeb.Components.ExampleCatalog

  def render(assigns) do
    ~H"""
    <.shell><.example_catalog /></.shell>
    """
  end
end
