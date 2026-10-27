defmodule AgentExamplesWeb.Components.Quicksort.Session do
  @moduledoc "Mount hook for sorting commands, recorded progress and root lifecycle observation."
  import Phoenix.Component
  import Phoenix.LiveView
  import AgentExamplesWeb.ExampleComponents, only: [own: 1, active?: 1]
  alias AgentExamplesWeb.ExamplePage

  def on_mount(:default, _params, _session, socket) do
    socket =
      assign(socket,
        tree: AgentExamples.Quicksort.TreeView.new(),
        sort_topic: nil,
        started_at: nil,
        elapsed: nil,
        history_available: true,
        root_monitor: nil,
        root_unavailable: nil,
        restarting: false,
        focus: "root",
        size: 4096
      )

    {:cont,
     socket
     |> restore_session_history()
     |> attach_hook(:quicksort_commands, :handle_event, &handle_event/3)
     |> attach_hook(:quicksort_progress, :handle_info, &handle_info/2)
     |> attach_hook(:quicksort_restart, :handle_async, &handle_async/3)}
  end

  defp restore_session_history(socket) do
    topic = own(socket.assigns.run)[:topic]

    if is_binary(topic) && topic != "" do
      socket = assign(socket, sort_topic: topic)

      socket =
        if connected?(socket) do
          Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

          if active?(socket.assigns.run),
            do: assign(socket, root_monitor: Process.monitor(socket.assigns.run.record.pid)),
            else: socket
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

  defp handle_event("restart_sort", _, %{assigns: %{starting: true}} = socket),
    do: {:halt, socket}

  defp handle_event("restart_sort", _, socket) do
    owner = socket.assigns.owner

    socket = socket |> release_root_monitor() |> put_private(:quicksort_pending, %{})

    if socket.assigns.sort_topic do
      Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)
    end

    {:halt,
     socket
     |> assign(starting: true, restarting: true, error: nil)
     |> start_async(:restart_sort, fn ->
       AgentExamples.Quicksort.Restart.restart(owner)
     end)}
  end

  defp handle_event("sort", %{"size" => size}, socket) do
    with {size, ""} when size in 1..100_000 <- Integer.parse(size),
         true <-
           !socket.assigns.starting && active?(socket.assigns.run) &&
             own(socket.assigns.run)[:status] == :idle do
      if socket.assigns.sort_topic do
        Phoenix.PubSub.unsubscribe(AgentExamples.PubSub, socket.assigns.sort_topic)
        AgentExamples.Quicksort.RunHistory.close(socket.assigns.sort_topic)
      end

      topic = AgentExamples.Quicksort.RunHistory.topic(Ash.UUIDv7.generate())
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
        {:halt,
         assign(socket, error: "Start the example and choose between 1 and 100,000 values.")}
    end
  end

  defp handle_event("focus", %{"branch" => branch}, socket),
    do: {:halt, assign(socket, focus: branch)}

  defp handle_event(_, _, socket), do: {:cont, socket}

  defp handle_async(:restart_sort, {:ok, {:ok, run}}, socket) do
    {:halt,
     assign(socket,
       run: run,
       starting: false,
       restarting: false,
       history_available: true,
       root_unavailable: nil,
       tree: AgentExamples.Quicksort.TreeView.new(),
       sort_topic: nil,
       started_at: nil,
       elapsed: nil,
       focus: "root",
       error: nil
     )}
  end

  defp handle_async(:restart_sort, {:ok, {:error, reason}}, socket),
    do: {:halt, assign(socket, starting: false, restarting: false, error: reason)}

  defp handle_async(:restart_sort, {:exit, reason}, socket),
    do:
      {:halt,
       assign(socket,
         starting: false,
         restarting: false,
         error: "Could not restart: #{inspect(reason)}"
       )}

  defp handle_async(_, _, socket), do: {:cont, socket}

  defp handle_info({:quicksort_progress, topic, node}, %{assigns: %{sort_topic: topic}} = socket) do
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

    {:halt, put_private(socket, :quicksort_pending, Map.put(pending, node.branch, node))}
  end

  defp handle_info(:flush_quicksort_progress, socket) do
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

    {:halt,
     socket |> put_private(:quicksort_pending, %{}) |> assign(tree: tree, elapsed: elapsed)}
  end

  defp handle_info({:quicksort_progress, _, _}, socket), do: {:halt, socket}

  defp handle_info({:DOWN, ref, :process, _, reason}, %{assigns: %{root_monitor: ref}} = socket),
    do: {:halt, assign(socket, root_unavailable: inspect(reason), root_monitor: nil)}

  defp handle_info(_, socket), do: {:cont, socket}

  defp release_root_monitor(socket) do
    if socket.assigns.root_monitor, do: Process.demonitor(socket.assigns.root_monitor, [:flush])
    assign(socket, root_monitor: nil)
  end
end
