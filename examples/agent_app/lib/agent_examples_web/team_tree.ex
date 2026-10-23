defmodule AgentExamplesWeb.TeamTree do
  @moduledoc "Live team diagram with locally selected, continuously updated agent details."
  use Phoenix.LiveComponent
  alias AgentExamplesWeb.TeamTreeLayout

  @impl true
  def update(assigns, socket) do
    nodes =
      if assigns.run, do: TeamTreeLayout.nodes(assigns.run.snapshot, assigns.root_name), else: %{}

    run_id = assigns.run && assigns.run.record.id
    reset? = socket.assigns[:run_id] != run_id
    focus = if reset?, do: "[]", else: socket.assigns[:focus] || "[]"
    selected = if reset?, do: nil, else: socket.assigns[:selected]
    focus = if Map.has_key?(nodes, focus), do: focus, else: "[]"

    {:ok,
     socket
     |> assign(assigns)
     |> assign(nodes: nodes, run_id: run_id, focus: focus, selected: selected)}
  end

  @impl true
  def handle_event("select", %{"node" => key}, socket),
    do: {:noreply, assign(socket, selected: if(Map.has_key?(socket.assigns.nodes, key), do: key))}

  def handle_event("close", _, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("focus", %{"node" => key}, socket) do
    if Map.has_key?(socket.assigns.nodes, key),
      do: {:noreply, assign(socket, focus: key, selected: nil)},
      else: {:noreply, socket}
  end

  defp status(node, run) do
    cond do
      run.status == :stopped || !node.alive? -> :stopped
      node.activity -> node.activity.status
      true -> Map.get(node.snapshot.own, :status, :idle)
    end
  end

  defp color(status) when status in [:setup, :running, :sorting, :working], do: "#c18a2b"
  defp color(:completed), do: "#14776a"
  defp color(:failed), do: "#bd5547"
  defp color(:stopped), do: "#abb5af"
  defp color(_), do: "#719b95"

  defp stage(node, run) do
    if run.status == :stopped || !node.alive?,
      do: "Stopped",
      else: if(node.activity, do: node.activity.stage, else: "Ready")
  end

  @impl true
  def render(assigns) do
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
          <div class="sort-navigation">
            <button
              class="button"
              phx-click="focus"
              phx-target={@myself}
              phx-value-node={@nodes[@focus].parent || "[]"}
              disabled={@focus == "[]"}
            >Up one parent</button>
            <button
              class="button"
              phx-click="focus"
              phx-target={@myself}
              phx-value-node="[]"
              disabled={@focus == "[]"}
            >Back to root</button>
          </div>
        </div>
        <p class="sort-legend">
          <span>● Ready</span><span>● Working</span><span>● Completed</span><span style="color:#bd5547">● Failed</span><span style="color:#abb5af">● Stopped</span>
        </p>
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
            stroke="#b3cfc0"
          />
          <g
            :for={node <- @diagram.nodes}
            role="button"
            tabindex="0"
            aria-label={"#{node.name}: #{stage(node, @run)}"}
            phx-click="select"
            phx-keydown="select"
            phx-key="Enter"
            phx-target={@myself}
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
              stroke={if node.team?, do: "#c4dcd3", else: "#fff"}
              stroke-width="3"
            />
            <text x={node.x} y={node.y + 24} text-anchor="middle">
              {if String.length(node.name) > 24,
                do: String.slice(node.name, 0, 23) <> "…",
                else: node.name}
            </text>
          </g>
        </svg>
        <p class="muted">
          Teams have larger nodes. Showing up to four levels and 80 nodes; focus a branch from its details to explore deeper.
        </p>
      </div>
      <div :if={@selected_node} class="agent-dialog-backdrop">
        <.focus_wrap id="agent-details-focus">
          <section
            id="agent-details"
            class="agent-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="agent-details-title"
            phx-mounted={
              Phoenix.LiveView.JS.push_focus()
              |> Phoenix.LiveView.JS.focus(to: "#agent-details button")
            }
            phx-remove={Phoenix.LiveView.JS.pop_focus()}
            phx-click-away="close"
            phx-window-keydown="close"
            phx-key="Escape"
            phx-target={@myself}
          >
            <div class="section-heading">
              <h2 id="agent-details-title">{@selected_node.name}</h2>
              <button
                class="button"
                phx-click="close"
                phx-target={@myself}
                aria-label="Close agent details"
              >Close</button>
            </div>
            <p class="muted">{@selected_node.path}</p>
            <p class="status-pill">{stage(@selected_node, @run)}</p>
            <dl>
              <dt>Agent ID</dt><dd>{@selected_node.snapshot.id}</dd><dt>Resource</dt><dd>
                {inspect(@selected_node.snapshot.resource)}
              </dd>
            </dl>
            <button
              class="button secondary"
              phx-click="focus"
              phx-target={@myself}
              phx-value-node={@selected_node.key}
            >Focus on this branch</button>
            <.agent_activity :if={@selected_node.activity} activity={@selected_node.activity} />
            <details :if={map_size(@selected_node.snapshot.own) > 0} open={!@selected_node.activity}>
              <summary>State</summary><pre>{inspect(@selected_node.snapshot.own, pretty: true)}</pre>
            </details>
          </section>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  attr :activity, :map, required: true

  defp agent_activity(assigns) do
    ~H"""
    <div class="agent-activity-detail">
      <p class="muted">Model turns: {@activity.iteration}</p>
      <h3 :if={@activity.task}>Current task</h3><pre :if={@activity.task}>{@activity.task}</pre>
      <div :if={@activity.tools != []} class="agent-tools">
        <p class="muted">Tools used for this task · latest first</p>
        <details :for={tool <- Enum.reverse(@activity.tools)} data-tool-status={tool.status}>
          <summary>
            {tool.label}<span>{case tool.status do
              :pending -> "Pending result"
              :completed -> "Succeeded"
              :failed -> "Failed"
              :unfinished -> "Run ended without result"
            end}</span>
          </summary>
          <small>Tool: {tool.name}</small><pre>{tool.input}</pre>
          <details :if={tool.result}>
            <summary>Tool result</summary><pre>{tool.result}</pre>
          </details>
        </details>
      </div>
      <h3 :if={@activity.output not in [nil, ""]}>Latest output</h3>
      <pre :if={@activity.output not in [nil, ""]}>{@activity.output}</pre>
      <p :if={@activity.error} class="error-banner">{inspect(@activity.error)}</p>
    </div>
    """
  end
end
