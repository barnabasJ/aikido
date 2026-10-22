defmodule AgentExamples.Quicksort.Bench.LifecycleProbe do
  @moduledoc false
  use GenServer

  def start(root, size, topic), do: GenServer.start(__MODULE__, {root, size, topic})
  def await(pid), do: GenServer.call(pid, :await, 600_000)

  def capture_ready(_event, _measurements, metadata, {collector, root_id}) do
    if String.starts_with?(metadata.agent_id, root_id <> "/"),
      do: GenServer.call(collector, {:ready, metadata.agent_id, self()}, 60_000)
  end

  @impl true
  def init({root, size, topic}) do
    Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

    :telemetry.attach(
      {__MODULE__, self()},
      [:aikido, :agent_server, :ready],
      &__MODULE__.capture_ready/4,
      {self(), root.id}
    )

    Process.send_after(self(), :sample, 1_000)

    {:ok,
     %{
       root: root,
       expected: size,
       ids: MapSet.new([root.id]),
       live: %{},
       completed: MapSet.new(),
       peak_agents: 1,
       peak_memory: :erlang.memory(:total),
       failures: [],
       waiter: nil
     }}
  end

  @impl true
  def handle_call(:await, from, state), do: finish_if_retired(%{state | waiter: from})

  def handle_call({:ready, id, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = %{state | ids: MapSet.put(state.ids, id), live: Map.put(state.live, ref, pid)}
    {:reply, :ok, %{state | peak_agents: max(state.peak_agents, map_size(state.live) + 1)}}
  end

  @impl true

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    failures =
      if clean_exit?(reason),
        do: state.failures,
        else: [inspect(reason) | state.failures]

    finish_if_retired(%{state | live: Map.delete(state.live, ref), failures: failures})
  end

  def handle_info({:quicksort_progress, _, %{status: :completed, branch: branch}}, state),
    do: finish_if_retired(%{state | completed: MapSet.put(state.completed, branch)})

  def handle_info({:quicksort_progress, _, _}, state), do: {:noreply, state}

  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, 1_000)
    {:noreply, %{state | peak_memory: max(state.peak_memory, :erlang.memory(:total))}}
  end

  defp finish_if_retired(state) do
    if state.waiter && map_size(state.live) == 0 && MapSet.size(state.completed) == state.expected &&
         MapSet.size(state.ids) == state.expected do
      GenServer.reply(
        state.waiter,
        Map.take(state, [:peak_agents, :peak_memory, :failures])
        |> Map.put(:spawned, MapSet.size(state.ids))
      )

      {:noreply, %{state | waiter: nil}}
    else
      {:noreply, state}
    end
  end

  defp clean_exit?(reason) when reason in [:normal, :shutdown, {:shutdown, :delete}], do: true
  defp clean_exit?({:shutdown, {:parent_down, reason}}), do: clean_exit?(reason)
  defp clean_exit?(_), do: false

  @impl true
  def terminate(_, _), do: :telemetry.detach({__MODULE__, self()})
end
