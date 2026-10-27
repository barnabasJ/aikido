defmodule AgentExamplesWeb.VerifiedWorkLive do
  @moduledoc "Atomic task delivery and native evidence verification."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  import AgentExamplesWeb.Components.Conversation, only: [conversation: 1]
  import AgentExamplesWeb.Components.VerifiedWork, only: [verified_work: 1]
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "verified-work"})
  on_mount({AgentExamplesWeb.Components.VerifiedWork, :default})
  on_mount({AgentExamplesWeb.Components.Conversation, :ask})

  def render(assigns) do
    ~H"""
    <.page {assigns}>
      <.verified_work run={@run} />
      <.conversation run={@run} />
    </.page>
    """
  end
end
