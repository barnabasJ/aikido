defmodule AgentExamples.Quicksort.RunHistory do
  @moduledoc "Session-owned display summaries and coalesced updates, independent of live sorting agents."
  use GenServer
  alias AgentExamples.Quicksort.TreeView
  @flush_interval 100

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def topic(root_id), do: "quicksort:" <> root_id
  def open(topic), do: GenServer.call(__MODULE__, {:open, topic})
  def fetch(topic), do: GenServer.call(__MODULE__, {:fetch, topic})
  def elapsed(topic), do: GenServer.call(__MODULE__, {:elapsed, topic})
  def close(topic), do: GenServer.call(__MODULE__, {:close, topic})

  def record(topic, node),
    do: GenServer.cast(__MODULE__, {:record, topic, node, System.monotonic_time(:millisecond)})

  @impl true
  def init(_), do: {:ok, %{histories: %{}, pending: %{}, timings: %{}, timer: nil}}

  @impl true
  def handle_call({:open, topic}, _from, state) do
    {:reply, :ok,
     %{
       state
       | histories: Map.put(state.histories, topic, TreeView.new()),
         timings:
           Map.put(state.timings, topic, %{
             started: System.monotonic_time(:millisecond),
             completed: nil
           }),
         pending: Map.delete(state.pending, topic)
     }}
  end

  def handle_call({:fetch, topic}, _from, state),
    do: {:reply, Map.fetch(state.histories, topic), state}

  def handle_call({:elapsed, topic}, _from, state) do
    result =
      case state.timings[topic] do
        %{started: started, completed: completed} when is_integer(completed) ->
          {:ok, completed - started}

        _ ->
          :pending
      end

    {:reply, result, state}
  end

  def handle_call({:close, topic}, _from, state) do
    {:reply, :ok,
     %{
       state
       | histories: Map.delete(state.histories, topic),
         timings: Map.delete(state.timings, topic),
         pending: Map.delete(state.pending, topic)
     }}
  end

  @impl true
  def handle_cast({:record, topic, node, recorded_at}, state) do
    case Map.fetch(state.histories, topic) do
      {:ok, tree} ->
        updated = TreeView.put_node(tree, node)

        if updated == tree do
          {:noreply, state}
        else
          pending =
            Map.update(
              state.pending,
              topic,
              %{node.branch => node},
              &Map.put(&1, node.branch, node)
            )

          timer = state.timer || Process.send_after(self(), :flush_progress, @flush_interval)

          {:noreply,
           %{
             state
             | histories: Map.put(state.histories, topic, updated),
               timings: complete_timing(state.timings, topic, node, recorded_at),
               pending: pending,
               timer: timer
           }}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp complete_timing(timings, topic, %{branch: "root", status: :completed}, recorded_at),
    do: Map.update!(timings, topic, &%{&1 | completed: &1.completed || recorded_at})

  defp complete_timing(timings, _topic, _node, _recorded_at), do: timings

  @impl true
  def handle_info(:flush_progress, state) do
    Enum.each(state.pending, fn {topic, nodes} ->
      Phoenix.PubSub.broadcast(
        AgentExamples.PubSub,
        topic,
        {:quicksort_progress_batch, topic, Map.values(nodes)}
      )
    end)

    {:noreply, %{state | pending: %{}, timer: nil}}
  end
end
