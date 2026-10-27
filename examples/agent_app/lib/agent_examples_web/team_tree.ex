defmodule AgentExamplesWeb.TeamTree do
  @moduledoc "Live team diagram with locally selected, continuously updated agent details."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [inspected_value: 1]

  import AgentExamplesWeb.Components.UI,
    only: [tool_call: 1, tree_navigation: 1, status_legend: 1, status_pill: 1, section_heading: 1]

  import Phoenix.LiveView
  import AgentExamplesWeb.Markdown
  alias AgentExamplesWeb.TeamTreeLayout

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign_new(:team_trees, fn -> %{} end)
     |> attach_hook(:team_tree_events, :handle_event, &handle_tree_event/3)}
  end

  defp handle_tree_event(event, %{"tree" => id} = params, socket)
       when event in ["team_tree:select", "team_tree:close", "team_tree:focus"] do
    run = socket.assigns.run
    nodes = if run, do: TeamTreeLayout.nodes(run.snapshot, "Team"), else: %{}
    state = current_selection(socket.assigns.team_trees[id] || %{}, run)
    key = params["node"]

    state =
      case event do
        "team_tree:close" ->
          %{state | selected: nil}

        "team_tree:select" ->
          %{state | selected: if(Map.has_key?(nodes, key), do: key)}

        "team_tree:focus" ->
          if Map.has_key?(nodes, key), do: %{state | focus: key, selected: nil}, else: state
      end

    {:halt, assign(socket, team_trees: Map.put(socket.assigns.team_trees, id, state))}
  end

  defp handle_tree_event(_, _, socket), do: {:cont, socket}

  defp current_selection(state, run) do
    run_id = run && run.record.id

    if state[:run_id] == run_id,
      do: Map.merge(%{focus: "[]", selected: nil, run_id: run_id}, state),
      else: %{focus: "[]", selected: nil, run_id: run_id}
  end

  defp status(node, run) do
    cond do
      run.status == :stopped || !node.alive? -> :stopped
      node.activity -> node.activity.status
      true -> Map.get(node.snapshot.own, :status, :idle)
    end
  end

  defp color(status) when status in [:setup, :running, :sorting, :working], do: "var(--working)"
  defp color(:completed), do: "var(--success)"
  defp color(:failed), do: "var(--accent)"
  defp color(:stopped), do: "var(--stopped)"
  defp color(_), do: "var(--ready)"

  defp stage(node, run) do
    if run.status == :stopped || !node.alive?,
      do: "Stopped",
      else: if(node.activity, do: node.activity.stage, else: "Ready")
  end

  attr :id, :string, required: true
  attr :run, :any, required: true
  attr :root_name, :string, default: "Team"
  attr :selection, :map, default: %{}

  def tree(assigns) do
    nodes =
      if assigns.run, do: TeamTreeLayout.nodes(assigns.run.snapshot, assigns.root_name), else: %{}

    selection = current_selection(assigns.selection, assigns.run)
    focus = if Map.has_key?(nodes, selection.focus), do: selection.focus, else: "[]"
    assigns = assign(assigns, nodes: nodes, focus: focus, selected: selection.selected)

    assigns =
      assign(
        assigns,
        :diagram,
        if(map_size(assigns.nodes) > 0, do: TeamTreeLayout.diagram(assigns.nodes, assigns.focus))
      )

    assigns = assign(assigns, :selected_node, assigns.nodes[assigns.selected])

    assigns =
      assign(
        assigns,
        :active_count,
        Enum.count(assigns.nodes, fn {_, node} ->
          status(node, assigns.run) in [:setup, :running, :waiting, :working, :sorting]
        end)
      )

    ~H"""
    <div id={@id} class="team-tree">
      <p :if={!@diagram} class="muted">Start the example to bring this topology to life.</p>
      <div :if={@diagram}>
        <p :if={@run.status == :stopped} class="muted" id="previous-team-tree">
          Previous run · stopped. These are its last recorded nodes; starting again creates a new tree.
        </p>
        <div class="section-heading team-tree-toolbar">
          <p class="muted">
            {length(@diagram.nodes)} of {@diagram.total} agents · {@active_count} active · select a node for details
          </p>
          <.tree_navigation
            event="team_tree:focus"
            tree_id={@id}
            parent={@nodes[@focus].parent || "[]"}
            root="[]"
            at_root={@focus == "[]"}
          />
        </div>
        <.status_legend items={[
          {"● Ready", nil},
          {"● Working", nil},
          {"● Completed", nil},
          {"● Failed", "accent"},
          {"◌ Stopped", "stopped"}
        ]} />
        <.team_diagram {assigns} />
        <p class="muted">
          Teams have larger nodes. Showing up to four levels and 80 nodes; focus a branch from its details to explore deeper.
        </p>
      </div>
      <.agent_details {assigns} />
    </div>
    """
  end

  attr :activity, :map, required: true

  def agent_activity(assigns) do
    ~H"""
    <div class="agent-activity-detail">
      <p class="muted">Model turns: {@activity.iteration}</p>
      <h3 :if={@activity.task}>Current task</h3><.markdown :if={@activity.task} text={@activity.task} />
      <div :if={@activity.tools != []} class="agent-tools">
        <p class="muted">Tools used for this task · latest first</p>
        <.tool_call :for={tool <- Enum.reverse(@activity.tools)} tool={tool} />
      </div>
      <h3 :if={@activity.output not in [nil, ""]}>Latest output</h3>
      <.markdown :if={@activity.output not in [nil, ""]} text={@activity.output} />
      <p :if={@activity.error} class="error-banner">{inspect(@activity.error)}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :diagram, :map, required: true
  attr :run, :any, required: true

  def team_diagram(assigns) do
    ~H"""
    <svg
      class="team-diagram"
      viewBox={"0 0 960 #{@diagram.height}"}
      role="group"
      aria-label="Live team tree"
    >
      <line
        :for={{parent, child} <- @diagram.edges}
        x1={parent.x}
        y1={parent.y}
        x2={child.x}
        y2={child.y}
        stroke="var(--muted)"
      />
      <g
        :for={node <- @diagram.nodes}
        role="button"
        tabindex="0"
        aria-label={"#{node.name}: #{stage(node, @run)}"}
        phx-click="team_tree:select"
        phx-keydown="team_tree:select"
        phx-key="Enter"
        phx-value-tree={@id}
        phx-value-node={node.key}
        data-agent={node.path}
        data-node={node.name}
        data-status={status(node, @run)}
      >
        <title>{node.name} · {stage(node, @run)} · {node.snapshot.id}</title>
        <circle
          cx={node.x}
          cy={node.y}
          r={if node.team?, do: 10, else: 7}
          fill={color(status(node, @run))}
          stroke={if node.team?, do: "var(--signal)", else: "var(--panel)"}
          stroke-width="3"
        />
        <text x={node.x} y={node.y + 24} text-anchor="middle">
          {if String.length(node.name) > 24,
            do: String.slice(node.name, 0, 23) <> "…",
            else: node.name}
        </text>
      </g>
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :selected_node, :any, default: nil
  attr :run, :any, required: true

  def agent_details(assigns) do
    assigns =
      assign(
        assigns,
        :dialog_id,
        if(assigns.id == "team-tree", do: "agent-details", else: assigns.id <> "-details")
      )

    ~H"""
    <div :if={@selected_node} class="agent-dialog-backdrop">
      <.focus_wrap id={@dialog_id <> "-focus"}>
        <section
          id={@dialog_id}
          class="agent-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby={@dialog_id <> "-title"}
          phx-mounted={
            Phoenix.LiveView.JS.push_focus()
            |> Phoenix.LiveView.JS.focus(to: "##{@dialog_id} button")
          }
          phx-remove={Phoenix.LiveView.JS.pop_focus()}
          phx-click-away="team_tree:close"
          phx-window-keydown="team_tree:close"
          phx-key="Escape"
          phx-value-tree={@id}
        >
          <.section_heading title_id={@dialog_id <> "-title"}>
            <:title>{@selected_node.name}</:title>
            <button
              class="button"
              phx-click="team_tree:close"
              phx-value-tree={@id}
              aria-label="Close agent details"
            >Close</button>
          </.section_heading>
          <p class="muted">{@selected_node.path}</p>
          <.status_pill tag={:p}>{stage(@selected_node, @run)}</.status_pill>
          <dl>
            <dt>Agent ID</dt><dd>{@selected_node.snapshot.id}</dd><dt>Resource</dt><dd>
              {inspect(@selected_node.snapshot.resource)}
            </dd>
          </dl>
          <button
            class="button secondary"
            phx-click="team_tree:focus"
            phx-value-tree={@id}
            phx-value-node={@selected_node.key}
          >Focus on this branch</button>
          <.agent_activity :if={@selected_node.activity} activity={@selected_node.activity} />
          <details :if={map_size(@selected_node.snapshot.own) > 0} open={!@selected_node.activity}>
            <summary>State</summary><.inspected_value value={@selected_node.snapshot.own} />
          </details>
        </section>
      </.focus_wrap>
    </div>
    """
  end
end
