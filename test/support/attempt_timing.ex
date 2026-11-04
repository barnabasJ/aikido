defmodule Aikido.AttemptTimingTest.Manual do
  @moduledoc "Case-owned deterministic I/O clock; never mounted on an agent."
  use GenServer
  @behaviour Aikido.AiReact.AttemptTiming

  def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
  def advance(clock, time), do: GenServer.call(clock, {:advance, time})
  @impl true
  def init(observer),
    do: {:ok, %{now: 0, base: System.system_time(:millisecond), timers: %{}, observer: observer}}

  @impl true
  def monotonic_ms(clock), do: GenServer.call(clock, :monotonic)
  @impl true
  def system_ms(clock), do: GenServer.call(clock, :system)
  @impl true
  def schedule_at(clock, target, tag, deadline),
    do: GenServer.call(clock, {:arm, target, tag, deadline})

  @impl true
  def cancel_timer(clock, reference), do: GenServer.call(clock, {:cancel, reference})
  @impl true
  def control_timeout(_clock, _remaining), do: 5_000

  @impl true
  def handle_call(:monotonic, _from, state), do: {:reply, state.now, state}
  def handle_call(:system, _from, state), do: {:reply, state.base + state.now, state}

  def handle_call({:cancel, reference}, _from, state),
    do: {:reply, :ok, %{state | timers: Map.delete(state.timers, reference)}}

  def handle_call({:arm, target, tag, deadline}, _from, state) do
    reference = make_ref()
    send(state.observer, {:armed, target, tag, deadline})

    if deadline <= state.now do
      send(target, tag)
      {:reply, reference, state}
    else
      {:reply, reference,
       %{state | timers: Map.put(state.timers, reference, {target, tag, deadline})}}
    end
  end

  def handle_call({:advance, time}, _from, state) when time >= state.now do
    {due, pending} =
      Enum.split_with(state.timers, fn {_ref, {_target, _tag, deadline}} -> deadline <= time end)

    Enum.each(Enum.sort_by(due, fn {_ref, {_target, _tag, deadline}} -> deadline end), fn {_ref,
                                                                                           {target,
                                                                                            tag,
                                                                                            _deadline}} ->
      send(target, tag)
    end)

    {:reply, :ok, %{state | now: time, timers: Map.new(pending)}}
  end
end
