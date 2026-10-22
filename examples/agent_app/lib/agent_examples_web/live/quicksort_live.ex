defmodule AgentExamplesWeb.QuicksortLive do
  @moduledoc "Inspect thousands of recursive sorting agents without rendering thousands of cards."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "quicksort"})

  def mount(_, _, socket) do
    socket =
      assign(socket,
        nodes: %{},
        sort_topic: nil,
        started_at: nil,
        elapsed: nil,
        focus: "root",
        size: 4096
      )

    {:ok, restore_retained_tree(socket)}
  end

  defp restore_retained_tree(socket) do
    if connected?(socket) && active?(socket.assigns.run) do
      pid = socket.assigns.run.record.pid

      with {:ok, topic} <- Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.topic}),
           true <- is_binary(topic) && topic != "" do
        Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

        socket
        |> assign(sort_topic: topic)
        |> start_async(:restore_tree, fn -> AgentExamples.Quicksort.TreeSnapshot.read(pid) end)
      else
        _ -> socket
      end
    else
      socket
    end
  end

  def handle_async(:restore_tree, {:ok, restored}, socket) do
    nodes =
      Enum.reduce(restored, socket.assigns.nodes, fn {_, node}, nodes ->
        adopt_node(nodes, node)
      end)

    {:noreply, assign(socket, nodes: nodes)}
  end

  def handle_async(:restore_tree, {:exit, _}, socket), do: {:noreply, socket}

  def handle_event("restart_sort", _, socket) do
    owner = socket.assigns.owner

    case AgentExamples.Playground.stop(owner, "quicksort") do
      :ok ->
        if socket.assigns.sort_topic,
          do: Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)

        {:noreply,
         socket
         |> assign(
           run: AgentExamples.Playground.get(owner, "quicksort"),
           starting: true,
           nodes: %{},
           sort_topic: nil,
           started_at: nil,
           elapsed: nil,
           focus: "root",
           error: nil
         )
         |> start_async(:start_example, fn ->
           AgentExamples.Playground.start(owner, "quicksort", %{})
         end)}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}
    end
  end

  def handle_event("sort", %{"size" => size}, socket) do
    with {size, ""} when size in 1..100_000 <- Integer.parse(size),
         true <- active?(socket.assigns.run) do
      if socket.assigns.sort_topic,
        do: Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)

      topic = "quicksort:" <> Ash.UUIDv7.generate()
      :ok = Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

      socket =
        assign(socket,
          nodes: %{},
          sort_topic: topic,
          started_at: System.monotonic_time(:millisecond),
          elapsed: nil,
          focus: "root",
          size: size
        )

      ExamplePage.command(socket, :sort, %{
        numbers: Enum.shuffle(Enum.to_list(1..size)),
        topic: topic
      })
    else
      _ ->
        {:noreply,
         assign(socket, error: "Start the example and choose between 1 and 100,000 values.")}
    end
  end

  def handle_event("focus", %{"branch" => branch}, socket),
    do: {:noreply, assign(socket, focus: branch)}

  def handle_info({:quicksort_progress, topic, node}, %{assigns: %{sort_topic: topic}} = socket) do
    nodes = socket.assigns.nodes |> adopt_node(node) |> drain_progress(topic, 500)

    elapsed =
      if socket.assigns.started_at && nodes["root"] && nodes["root"].status == :completed,
        do:
          socket.assigns.elapsed ||
            System.monotonic_time(:millisecond) - socket.assigns.started_at,
        else: nil

    {:noreply, assign(socket, nodes: nodes, elapsed: elapsed)}
  end

  def handle_info({:quicksort_progress, _, _}, socket), do: {:noreply, socket}

  # Batch already delivered notifications into one render; never query agents repeatedly.
  defp drain_progress(nodes, _topic, 0), do: nodes

  defp drain_progress(nodes, topic, remaining) do
    receive do
      {:quicksort_progress, ^topic, node} ->
        nodes |> adopt_node(node) |> drain_progress(topic, remaining - 1)
    after
      0 -> nodes
    end
  end

  defp adopt_node(nodes, node) do
    case nodes[node.branch] do
      %{status: :completed} -> nodes
      %{status: :sorting} when node.status == :idle -> nodes
      _ -> Map.put(nodes, node.branch, node)
    end
  end

  defp visible_nodes(nodes, focus) do
    nodes
    |> Map.values()
    |> Enum.filter(&String.starts_with?(&1.branch, focus))
    |> Enum.sort_by(&{String.length(&1.branch), &1.branch})
    |> Enum.take(80)
  end

  defp diagram_nodes(nodes, focus) do
    nodes
    |> Map.values()
    |> Enum.filter(
      &(String.starts_with?(&1.branch, focus) &&
          String.length(&1.branch) <= String.length(focus) + 6)
    )
    |> Enum.sort_by(& &1.branch)
    |> Enum.map(fn node ->
      relative = String.replace_prefix(node.branch, focus, "")

      {left, width} =
        relative
        |> String.graphemes()
        |> Enum.reduce({0.0, 960.0}, fn direction, {left, width} ->
          {if(direction == "R", do: left + width / 2, else: left), width / 2}
        end)

      Map.merge(node, %{x: left + width / 2, y: 24 + String.length(relative) * 42})
    end)
  end

  defp node_color(:completed), do: "#187c69"
  defp node_color(:sorting), do: "#e3a641"
  defp node_color(:idle), do: "#879d99"

  def render(assigns) do
    assigns =
      assign(assigns,
        diagram: diagram_nodes(assigns.nodes, assigns.focus),
        completed: Enum.count(assigns.nodes, fn {_, node} -> node.status == :completed end),
        levels:
          assigns.nodes
          |> Map.values()
          |> Enum.frequencies_by(&(String.length(&1.branch) - 4))
          |> Enum.sort(),
        visible: visible_nodes(assigns.nodes, assigns.focus)
      )

    ~H"""
    <.page {assigns}>
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
              disabled={!active?(@run) || own(@run)[:status] != :idle}
            >Spawn sorting tree →</button>
            <button
              type="button"
              class="button"
              phx-click="restart_sort"
              disabled={!active?(@run) || @starting}
            >Restart example</button>
          </div>
        </form>
        <p class="muted">
          Restart releases the old tree and creates a fresh root. Then choose a size and spawn again.
        </p>
      </section>
      <section class="panel" id="sort-metrics">
        <h2>The BEAM at work</h2>
        <div class="hero-pills">
          <span id="sort-spawned">{map_size(@nodes)} agents spawned</span>
          <span>{map_size(@nodes) - @completed} sorting</span>
          <span>{@completed} completed</span>
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
        <p>
          Completed agents remain alive until the root stops. Counts describe this sorting run, not the whole BEAM VM.
        </p>
        <div class="sort-levels">
          <div :for={{depth, count} <- @levels} class="sort-level">
            <span>Depth {depth}</span><meter min="0" max={max(map_size(@nodes), 1)} value={count} /><strong>{count} agents</strong>
          </div>
        </div>
        <details :if={own(@run)[:status] == :completed} id="sort-result">
          <summary>Sorted {length(own(@run)[:result] || [])} values · show result</summary>
          <pre style="max-height:240px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere">{inspect(own(@run)[:result], limit: :infinity)}</pre>
        </details>
      </section>
      <section class="panel" id="sorting-tree">
        <div class="section-heading">
          <h2>Partition tree</h2>
          <button class="button" phx-click="focus" phx-value-branch="root">Back to root</button>
        </div>
        <p>Showing up to 80 nodes beneath {@focus}. Select a branch to inspect its descendants.
          The display is limited; process creation is not.</p>
        <p class="sort-legend">
          <span>● Spawned</span><span>● Sorting / waiting for children</span><span>● Completed</span>
        </p>
        <p class="muted">Live updates add nodes and change their color. Completed nodes stay visible.
          The diagram shows six levels at a time; select a node to zoom into its subtree.</p>
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
              stroke="#b3cfc0"
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
              fill="#26594f"
            >
              {node.count}
            </text>
          </g>
        </svg>
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
      </section>
    </.page>
    """
  end
end
