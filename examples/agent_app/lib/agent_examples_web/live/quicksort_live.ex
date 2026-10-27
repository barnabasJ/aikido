defmodule AgentExamplesWeb.QuicksortLive do
  @moduledoc "Inspect recursive sorting agents using shared function components and a session hook."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents, only: [page: 1]
  import AgentExamplesWeb.Components.Quicksort, only: [quicksort: 1]
  on_mount({AgentExamplesWeb.ExamplePage, "quicksort"})
  on_mount({AgentExamplesWeb.Components.Quicksort.Session, :default})

  def render(assigns) do
    ~H"""
    <.page {assigns} show_signal_activity={false}>
      <.quicksort
        run={@run}
        tree={@tree}
        focus={@focus}
        size={@size}
        starting={@starting}
        restarting={@restarting}
        history_available={@history_available}
        root_unavailable={@root_unavailable}
        elapsed={@elapsed}
      />
    </.page>
    """
  end
end
