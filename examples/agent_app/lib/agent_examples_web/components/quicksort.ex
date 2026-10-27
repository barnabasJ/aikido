defmodule AgentExamplesWeb.Components.Quicksort do
  @moduledoc "Sorting controls, partition visualization and depth statistics as function components."
  use Phoenix.Component
  import Aikido.Inspector.CodeBlock, only: [inspected_value: 1]

  import AgentExamplesWeb.Components.UI,
    only: [tree_navigation: 1, status_legend: 1, section_heading: 1]

  import AgentExamplesWeb.ExampleComponents, only: [own: 1, active?: 1, signal_activity: 1]

  defp node_color(:completed), do: "var(--success)"
  defp node_color(:sorting), do: "var(--working)"
  defp node_color(:idle), do: "var(--ready)"
  defp node_color(:failed), do: "var(--accent)"

  defp describe_sort_failure(%{child_id: id, reason: reason})
       when is_binary(id) and not is_map(reason),
       do:
         "Child #{id} exited before returning its sorted partition (#{inspect(reason)}). " <>
           "Check supervisor and storage errors in the runtime logs."

  defp describe_sort_failure(%{reason: reason}), do: describe_sort_failure(reason)

  defp describe_sort_failure({:already_started, id}) when is_binary(id),
    do: "Agent #{id} is already running"

  defp describe_sort_failure(reason), do: inspect(reason)

  attr :run, :any, required: true
  attr :tree, :map, required: true
  attr :focus, :string, default: "root"
  attr :size, :integer, default: 4096
  attr :starting, :boolean, default: false
  attr :restarting, :boolean, default: false
  attr :history_available, :boolean, default: true
  attr :root_unavailable, :any, default: nil
  attr :elapsed, :any, default: nil

  def quicksort(assigns) do
    assigns =
      assign(assigns, AgentExamples.Quicksort.TreeView.summarize(assigns.tree, assigns.focus))

    ~H"""
    <.sorting_controls {assigns} />
    <div class="sort-visualization">
      <section class="panel" id="sorting-tree">
        <.section_heading>
          <:title>Partition tree</:title>
          <.tree_navigation
            event="focus"
            value_key="branch"
            parent={String.slice(@focus, 0, max(String.length(@focus) - 1, 4))}
            root="root"
            at_root={@focus == "root"}
          />
        </.section_heading>
        <p :if={!@history_available} id="history-unavailable">
          This older run has no recorded session history. Restart the example to track every spawned agent across reconnects.
        </p>
        <p :if={@root_unavailable && active?(@run)} role="alert" id="sort-root-unavailable">
          The sorting root stopped: {@root_unavailable}. This run cannot continue.
        </p>
        <p :if={own(@run)[:status] == :failed} role="alert" id="sort-failure">
          Sorting failed: {describe_sort_failure(own(@run)[:error])}. Restart the example after addressing the activation failure.
        </p>
        <div :if={@history_available} class="hero-pills" id="sort-metrics">
          <span id="sort-spawned">{map_size(@tree.nodes)} agents spawned</span>
          <span>{map_size(@tree.nodes) - @completed - @failed} sorting</span>
          <span>{@completed} completed</span>
          <span :if={@failed > 0} id="sort-failed">{@failed} failed</span>
          <span id="sort-depth">Depth {if @levels == [],
            do: 0,
            else: @levels |> List.last() |> elem(0)}</span>
          <span id="sort-elapsed">{if @elapsed,
            do: "#{@elapsed / 1000}s to result",
            else:
              if(own(@run)[:status] == :completed,
                do: "Completed · restored view",
                else: "Waiting for result"
              )}</span>
        </div>
        <p>Showing up to 80 nodes beneath {@focus}. Select a branch to inspect its descendants.
          The display is limited; process creation is not.</p>
        <.status_legend items={[
          {"● Spawned", nil},
          {"● Sorting / waiting for children", nil},
          {"● Completed", nil},
          {"● Failed", "accent"}
        ]} />
        <p class="muted">Live updates add nodes and change their color. Completed nodes stay visible.
          The diagram shows six levels at a time; select a node to zoom into its subtree.</p>
        <.partition_diagram {assigns} />
        <.partition_list {assigns} />
      </section>
      <aside class="sort-sidebar">
        <.depth_breakdown {assigns} />
        <.signal_activity run={@run} />
      </aside>
    </div>
    """
  end

  attr :run, :any, required: true
  attr :size, :integer, default: 4096
  attr :starting, :boolean, default: false
  attr :restarting, :boolean, default: false

  def sorting_controls(assigns) do
    ~H"""
    <section class="panel">
      <h2>One partition, one agent</h2>
      <p>
        Shuffle unique integers, then sort them using a branching tree of real Aikido agents.
        Every nonempty partition gets a process, including single values. No AI provider is involved.
      </p>
      <form id="quicksort-form" phx-submit="sort">
        <label>Number of values<input
          name="size"
          type="number"
          min="1"
          max="100000"
          value={@size}
          required
        /></label>
        <div class="sort-controls" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
          <button
            type="submit"
            class="button primary"
            disabled={@starting || !active?(@run) || own(@run)[:status] != :idle}
          >Spawn sorting tree →</button>
          <button
            type="button"
            class="button"
            phx-click="restart_sort"
            disabled={!active?(@run) || @starting}
          >{if @restarting, do: "Releasing previous tree…", else: "Restart example"}</button>
        </div>
      </form>
      <p class="muted">
        Sorted children stop after their results reach the parent. Their recorded nodes stay visible.
        Restart removes the old tree and crash snapshots, checkpoints EKV, then creates a new root ID.
      </p>
    </section>
    """
  end

  attr :diagram, :list, required: true
  attr :focus, :string, default: "root"

  def partition_diagram(assigns) do
    ~H"""
    <svg
      viewBox="0 0 960 300"
      role="img"
      aria-label="Recursive partition tree; select a node to zoom"
      class="sort-diagram"
    >
      <g :for={node <- @diagram}>
        <line
          :if={node.branch != @focus}
          x1={node.x}
          y1={node.y}
          x2={
            Enum.find_value(@diagram, node.x, fn parent ->
              if parent.branch == String.slice(node.branch, 0..-2//1), do: parent.x
            end)
          }
          y2={node.y - 42}
          stroke="var(--muted)"
        />
      </g>
      <g
        :for={node <- @diagram}
        phx-click="focus"
        phx-value-branch={node.branch}
        style="cursor:pointer"
      >
        <title>{node.branch}: {node.count} values · {node.status}</title>
        <circle
          cx={node.x}
          cy={node.y}
          r="6"
          fill={node_color(node.status)}
          data-status={node.status}
        />
        <text
          :if={node.y < 110}
          x={node.x}
          y={node.y + 18}
          text-anchor="middle"
          font-size="11"
          fill="var(--text)"
        >
          {node.count}
        </text>
      </g>
    </svg>
    """
  end

  attr :visible, :list, required: true

  def partition_list(assigns) do
    ~H"""
    <div class="sort-tree-scroll">
      <button
        :for={node <- @visible}
        class="sort-node"
        phx-click="focus"
        phx-value-branch={node.branch}
      >
        <strong>{node.branch}</strong><span>{node.count} values</span><span>Pivot {node.pivot}</span><span>{node.status}</span>
      </button>
    </div>
    """
  end

  attr :run, :any, required: true
  attr :tree, :map, required: true
  attr :levels, :list, required: true

  def depth_breakdown(assigns) do
    ~H"""
    <section class="panel" id="sort-depth-breakdown">
      <h2>Agents by depth</h2>

      <p>
        Completed child agents are released; their recorded nodes remain visible. Counts describe this sorting run, not currently live processes.
      </p>
      <div class="sort-levels">
        <div :for={{depth, count} <- @levels} class="sort-level">
          <span>Depth {depth}</span><meter
            min="0"
            max={max(map_size(@tree.nodes), 1)}
            value={count}
          /><strong>{count} agents</strong>
        </div>
      </div>
      <details :if={own(@run)[:status] == :completed} id="sort-result">
        <summary>Sorted {length(own(@run)[:result] || [])} values · show result</summary>
        <.inspected_value
          value={own(@run)[:result]}
          limit={:infinity}
          pretty={false}
          style="max-height:240px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere"
        />
      </details>
    </section>
    """
  end
end
