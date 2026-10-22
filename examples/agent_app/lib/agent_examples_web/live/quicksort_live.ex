defmodule AgentExamplesWeb.QuicksortLive do
  @moduledoc "Inspect thousands of recursive sorting agents without rendering thousands of cards."
  use Phoenix.LiveView, layout: false
  import AgentExamplesWeb.ExampleComponents
  alias AgentExamplesWeb.ExamplePage
  on_mount({ExamplePage, "quicksort"})

  def mount(_, _, socket) do
    socket =
      assign(socket,
        tree: AgentExamples.Quicksort.TreeView.new(),
        sort_topic: nil,
        started_at: nil,
        elapsed: nil,
        history_available: true,
        root_monitor: nil,
        root_unavailable: nil,
        focus: "root",
        size: 4096
      )

    {:ok, restore_session_history(socket)}
  end

  defp restore_session_history(socket) do
    if active?(socket.assigns.run) do
      topic = AgentExamples.Quicksort.RunHistory.topic(socket.assigns.run.record.id)
      socket = assign(socket, sort_topic: topic)

      socket =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)
          assign(socket, root_monitor: Process.monitor(socket.assigns.run.record.pid))
        else
          socket
        end

      case AgentExamples.Quicksort.RunHistory.fetch(topic) do
        {:ok, tree} -> assign(socket, tree: tree)
        :error -> assign(socket, history_available: own(socket.assigns.run)[:status] == :idle)
      end
    else
      socket
    end
  end

  def handle_event("restart_sort", _, socket) do
    owner = socket.assigns.owner

    socket = socket |> release_root_monitor() |> put_private(:quicksort_pending, %{})

    case AgentExamples.Playground.stop(owner, "quicksort") do
      :ok ->
        if socket.assigns.sort_topic do
          Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)
          AgentExamples.Quicksort.RunHistory.close(socket.assigns.sort_topic)
        end

        {:noreply,
         socket
         |> assign(
           run: AgentExamples.Playground.get(owner, "quicksort"),
           starting: true,
           history_available: true,
           root_unavailable: nil,
           tree: AgentExamples.Quicksort.TreeView.new(),
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
      if socket.assigns.sort_topic do
        Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)
        AgentExamples.Quicksort.RunHistory.close(socket.assigns.sort_topic)
      end

      topic = AgentExamples.Quicksort.RunHistory.topic(socket.assigns.run.record.id)
      AgentExamples.Quicksort.RunHistory.open(topic)
      :ok = Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

      socket =
        assign(socket |> release_root_monitor() |> put_private(:quicksort_pending, %{}),
          history_available: true,
          root_unavailable: nil,
          root_monitor: Process.monitor(socket.assigns.run.record.pid),
          tree: AgentExamples.Quicksort.TreeView.new(),
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
    pending = Map.get(socket.private, :quicksort_pending, %{})

    if map_size(pending) == 0 do
      Process.send_after(self(), :flush_quicksort_progress, 100)
    end

    prior = Map.get(pending, node.branch)

    node =
      if prior &&
           (prior.status in [:completed, :failed] ||
              (prior.status == :sorting && node.status == :idle)), do: prior, else: node

    if node.branch == "root" && node.status in [:completed, :failed],
      do: send(self(), :flush_quicksort_progress)

    {:noreply, put_private(socket, :quicksort_pending, Map.put(pending, node.branch, node))}
  end

  def handle_info(:flush_quicksort_progress, socket) do
    pending = Map.get(socket.private, :quicksort_pending, %{})

    tree =
      Enum.reduce(pending, socket.assigns.tree, fn {_, node}, tree ->
        AgentExamples.Quicksort.TreeView.put_node(tree, node)
      end)

    elapsed =
      if socket.assigns.started_at && tree.nodes["root"] &&
           tree.nodes["root"].status == :completed,
         do:
           socket.assigns.elapsed ||
             System.monotonic_time(:millisecond) - socket.assigns.started_at,
         else: nil

    {:noreply,
     socket |> put_private(:quicksort_pending, %{}) |> assign(tree: tree, elapsed: elapsed)}
  end

  def handle_info({:quicksort_progress, _, _}, socket), do: {:noreply, socket}

  def handle_info({:DOWN, ref, :process, _, reason}, %{assigns: %{root_monitor: ref}} = socket),
    do: {:noreply, assign(socket, root_unavailable: inspect(reason), root_monitor: nil)}

  defp release_root_monitor(socket) do
    if socket.assigns.root_monitor, do: Process.demonitor(socket.assigns.root_monitor, [:flush])
    assign(socket, root_monitor: nil)
  end

  defp node_color(:completed), do: "#187c69"
  defp node_color(:sorting), do: "#e3a641"
  defp node_color(:idle), do: "#879d99"
  defp node_color(:failed), do: "#bd5547"

  def render(assigns) do
    assigns =
      assign(assigns, AgentExamples.Quicksort.TreeView.summarize(assigns.tree, assigns.focus))

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
        <p :if={!@history_available} id="history-unavailable">This older run has no recorded session history. Restart the example to track every spawned agent across reconnects.</p>
        <p :if={@root_unavailable && active?(@run)} role="alert" id="sort-root-unavailable">The sorting root stopped: {@root_unavailable}. This run cannot continue.</p>
        <p :if={own(@run)[:status] == :failed} role="alert" id="sort-failure">Sorting failed: {inspect(own(@run)[:error])}. Restart the example after addressing the activation failure.</p>
        <div :if={@history_available} class="hero-pills">
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
        <p>
          Completed agents remain alive until the root stops. Counts describe this sorting run, not the whole BEAM VM.
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
          <span>● Spawned</span><span>● Sorting / waiting for children</span><span>● Completed</span><span style="color:#bd5547">● Failed</span>
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
