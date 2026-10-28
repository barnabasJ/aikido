defmodule AgentExamplesWeb.NotificationsLive do
  @moduledoc "Interactive native Ash publication and agent subscription example."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Notifications, only: [notifications: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "notifications"})
  on_mount({AgentExamplesWeb.Components.Notifications, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.notifications run={@run} />
    </.page>
    """
  end
end
