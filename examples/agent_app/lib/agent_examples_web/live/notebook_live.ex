defmodule AgentExamplesWeb.NotebookLive do
  @moduledoc "Interactive notebook example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Notebook, only: [notebook: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "notebook"})
  on_mount({AgentExamplesWeb.Components.Notebook, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.notebook run={@run} />
    </.page>
    """
  end
end
