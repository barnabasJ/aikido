defmodule AgentExamplesWeb.ChecklistLive do
  @moduledoc "Interactive checklist example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Checklist, only: [checklist: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "checklist"})
  on_mount({AgentExamplesWeb.Components.Checklist, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.checklist run={@run} />
    </.page>
    """
  end
end
