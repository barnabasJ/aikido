defmodule AgentExamplesWeb.WorkerLive do
  @moduledoc "Interactive worker example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Worker, only: [worker: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "worker"})
  on_mount({AgentExamplesWeb.Components.Worker, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.worker run={@run} />
    </.page>
    """
  end
end
