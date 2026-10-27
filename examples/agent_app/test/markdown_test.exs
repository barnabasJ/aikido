defmodule AgentExamplesWeb.MarkdownTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "renders tables, lists and emphasis as native HTML" do
    html =
      render_component(&AgentExamplesWeb.Markdown.markdown/1,
        text: """
        ## Findings

        | Agent | Result |
        | --- | --- |
        | Researcher | **Complete** |

        - Verified evidence
        """
      )

    assert html =~ "<table>"
    assert html =~ "<th>Agent</th>"
    assert html =~ "<strong>Complete</strong>"
    assert html =~ "<li>Verified evidence</li>"
  end

  test "does not execute raw HTML or dangerous Markdown links" do
    html =
      render_component(&AgentExamplesWeb.Markdown.markdown/1,
        text:
          "<script>alert(1)</script>\n\n[click](javascript:alert(1))\n\n<img src=x onerror=alert(1)>"
      )

    refute html =~ "<script>"
    refute html =~ ~s(href="javascript:)
    refute html =~ "<img"
  end

  test "incomplete streamed Markdown keeps code as text" do
    html =
      render_component(&AgentExamplesWeb.Markdown.markdown/1,
        text: "```elixir\n<tag> & value"
      )

    assert html =~ "<pre><code"
    assert html =~ "&lt;tag&gt; &amp; value"
  end
end
