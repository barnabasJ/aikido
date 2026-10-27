defmodule AgentExamplesWeb.Markdown do
  @moduledoc "Renders conversation and agent output as sanitized Markdown in the playground."
  use Phoenix.Component

  attr :text, :string, default: ""

  def markdown(assigns) do
    html =
      MDEx.to_html!(assigns.text || "",
        extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
        render: [escape: true],
        sanitize: MDEx.Document.default_sanitize_options()
      )

    assigns = assign(assigns, :html, Phoenix.HTML.raw(html))

    ~H"""
    <div class="markdown-content">{@html}</div>
    """
  end
end
