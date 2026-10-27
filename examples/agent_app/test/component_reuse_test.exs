defmodule AgentExamplesWeb.ComponentReuseTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint AgentExamplesWeb.Endpoint

  test "packaged highlighting escapes plaintext markup and ignores caller HTML" do
    html =
      render_component(&Aikido.Inspector.CodeBlock.highlighted_code/1,
        text: Jason.encode!(%{text: "<script>alert('x')</script>"}),
        html: "<script>override()</script>"
      )

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "override()"
    assert html =~ ~s(class=")
  end

  defmodule MetadataLexer do
    def lex(text), do: [{:string, %{group_id: ~s|" onclick="alert('x')|}, text}]
  end

  test "highlighting escapes custom lexer metadata and preserves exact source whitespace" do
    source = "first\n  <script>\"text\" & 'value'</script>\n"

    html =
      render_component(&Aikido.Inspector.CodeBlock.highlighted_code/1,
        text: source,
        lexer: MetadataLexer
      )

    parsed = LazyHTML.from_document(html)
    assert parsed |> LazyHTML.query("code") |> LazyHTML.text() == source
    assert Enum.empty?(LazyHTML.query(parsed, "[onclick]"))
    assert Enum.empty?(LazyHTML.query(parsed, "script"))
    assert parsed |> LazyHTML.query("span") |> LazyHTML.attribute("class") == ["s"]

    assert parsed |> LazyHTML.query("span") |> LazyHTML.attribute("data-group-id") == [
             ~s|" onclick="alert('x')|
           ]
  end

  defmodule InspectorHost do
    use Phoenix.LiveView, layout: false
    alias Aikido.Inspector.History
    on_mount({Aikido.Inspector.Components, :default})

    def mount(_, _, socket), do: {:ok, assign(socket, inspection: append(History.new(), 1))}

    def handle_info({:append, value}, socket),
      do: {:noreply, assign(socket, inspection: append(socket.assigns.inspection, value))}

    defp append(history, value) do
      History.record(
        history,
        %{id: "standalone", inspected_state: %{count: value}},
        [],
        %{signal: %{type: "counter.changed"}, directives: [], error: nil},
        %{},
        self()
      )
    end

    def render(assigns) do
      ~H"""
      <Aikido.Inspector.Components.inspector
        history={@inspection}
        selected={@inspection_selected}
        view={@inspection_view}
        format={@inspection_format}
        filter={@inspection_filter}
      />
      """
    end
  end

  test "packaged inspector mounts independently and keeps the selected entry when history changes" do
    {:ok, view, _} = live_isolated(build_conn(), InspectorHost)
    view |> element(".inspector-row > button[phx-value-sequence='1']") |> render_click()
    send(view.pid, {:append, 2})
    assert has_element?(view, ".inspector-row > button[phx-value-sequence='2']")

    assert has_element?(
             view,
             ".inspector-row > button[phx-value-sequence='1'][aria-pressed='true']"
           )

    view |> element("button[phx-click='inspection_live']") |> render_click()

    assert has_element?(
             view,
             ".inspector-row > button[phx-value-sequence='2'][aria-pressed='true']"
           )
  end

  defmodule TreeHost do
    use Phoenix.LiveView, layout: false
    import AgentExamplesWeb.TeamTree, only: [tree: 1]
    on_mount({__MODULE__, :fixture})
    on_mount({AgentExamplesWeb.TeamTree, :default})

    def on_mount(:fixture, _, _, socket) do
      child = %{
        id: "root/worker",
        resource: AgentExamples.Worker,
        team?: false,
        activity: nil,
        own: %{status: :idle},
        members: [],
        children: %{}
      }

      snapshot = %{
        id: "root",
        resource: AgentExamples.Team,
        team?: true,
        activity: nil,
        own: %{},
        members: [%{name: "worker", owner: nil, dynamic: true, alive: true}],
        children: %{"worker" => child}
      }

      {:cont, assign(socket, run: %{status: :running, record: %{id: "root"}, snapshot: snapshot})}
    end

    def render(assigns) do
      ~H"""
      <.tree id="first" run={@run} selection={@team_trees["first"] || %{}} />
      <.tree id="second" run={@run} selection={@team_trees["second"] || %{}} />
      """
    end
  end

  test "function trees can share a LiveView without sharing selection or dialog IDs" do
    {:ok, view, _} = live_isolated(build_conn(), TreeHost)
    view |> element("#first g[data-node=worker]") |> render_click()
    assert has_element?(view, "#first-details", "root/worker")
    refute has_element?(view, "#second-details")

    view |> element("#second g[data-node=worker]") |> render_click()
    assert has_element?(view, "#first-details")
    assert has_element?(view, "#second-details", "root/worker")

    view |> element("#first-details button[phx-click='team_tree:close']") |> render_click()
    refute has_element?(view, "#first-details")
    assert has_element?(view, "#second-details")
    view |> element("#second-details button[phx-click='team_tree:focus']") |> render_click()
    assert has_element?(view, "#first g[data-node=Team]")
    refute has_element?(view, "#second g[data-node=Team]")
  end
end
