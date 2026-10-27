defmodule AgentExamples.Telemetry.Observations do
  @moduledoc """
  Retains telemetry totals and bounded request summaries from application startup.

  High-volume signal/directive events update ETS counters directly. Only provider
  request lifecycle events enter this server's mailbox. Stored fields are an
  explicit metadata allowlist: no prompts, responses, credentials or error bodies.
  """
  use GenServer
  alias AgentExamples.Telemetry.Usage
  @table __MODULE__
  @keys [
    :signals_sent,
    :signals_processed,
    :signal_errors,
    :directives,
    :directive_errors,
    :activations,
    :llm_started,
    :llm_finished,
    :llm_exceptions,
    :llm_retries,
    :llm_http_errors
  ]
  @limit 50

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @doc "Read totals since startup plus at most fifty active and fifty recent request summaries."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :telemetry.detach(@table)

    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    Enum.each(@keys, &:ets.insert(@table, {&1, 0}))

    events =
      [
        [:aikido, :agent_server, :signal, :sent],
        [:aikido, :agent_server, :signal, :stop],
        [:aikido, :agent_server, :signal, :exception],
        [:aikido, :agent_server, :directive, :stop],
        [:aikido, :agent_server, :directive, :exception],
        [:aikido, :agent_server, :ready]
      ] ++ for phase <- [:start, :stop, :exception, :retry], do: [:req_llm, :request, phase]

    :ok = :telemetry.attach_many(@table, events, &__MODULE__.handle_event/4, nil)
    {:ok, %{started_at: DateTime.utc_now(), active: %{}, recent: [], usage: %{}, missing_cost: 0}}
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(@table)

  def handle_event([:aikido, :agent_server, :signal, :sent], _, _, _),
    do: increment(:signals_sent)

  def handle_event([:aikido, :agent_server, :signal, :stop], _, metadata, _) do
    increment(:signals_processed)
    if Map.has_key?(metadata, :error), do: increment(:signal_errors)
  end

  def handle_event([:aikido, :agent_server, :signal, :exception], _, _, _),
    do: increment(:signal_errors)

  def handle_event([:aikido, :agent_server, :directive, :stop], _, _, _),
    do: increment(:directives)

  def handle_event([:aikido, :agent_server, :directive, :exception], _, _, _),
    do: increment(:directive_errors)

  def handle_event([:aikido, :agent_server, :ready], _, _, _), do: increment(:activations)

  def handle_event([:req_llm, :request, phase], measurements, metadata, _) do
    summary =
      metadata
      |> Map.take([
        :request_id,
        :provider,
        :model,
        :mode,
        :operation,
        :http_status,
        :finish_reason
      ])
      |> Map.new(fn
        {:model, %LLMDB.Model{id: id}} -> {:model, id}
        {key, value} -> {key, scalar(value)}
      end)
      |> Map.merge(%{
        pid: self(),
        duration_ms: duration_ms(measurements[:duration]),
        usage:
          Map.new(
            [:input_tokens, :output_tokens, :reasoning_tokens, :total_cost],
            &{&1, Usage.reported(metadata[:usage], &1)}
          )
      })

    GenServer.cast(__MODULE__, {:request, phase, summary})
  end

  @impl true
  def handle_call(:snapshot, _, state) do
    now = System.monotonic_time(:millisecond)

    active =
      state.active
      |> Enum.take(@limit)
      |> Enum.map(fn {_, request} ->
        request |> Map.drop([:monitor]) |> Map.put(:elapsed_ms, now - request.started_ms)
      end)

    snapshot =
      %{state | active: active}
      |> Map.put(:active_count, map_size(state.active))
      |> Map.put(:totals, Map.new(:ets.tab2list(@table)))

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:request, :start, request}, state) do
    increment(:llm_started)

    if current = state.active[request.request_id],
      do: Process.demonitor(current.monitor, [:flush])

    request =
      Map.merge(request, %{
        monitor: Process.monitor(request.pid),
        started_ms: System.monotonic_time(:millisecond)
      })

    {:noreply, put_in(state.active[request.request_id], request)}
  end

  def handle_cast({:request, :retry, _}, state) do
    increment(:llm_retries)
    {:noreply, state}
  end

  def handle_cast({:request, phase, request}, state) when phase in [:stop, :exception] do
    increment(if phase == :stop, do: :llm_finished, else: :llm_exceptions)
    http_error? = is_integer(request[:http_status]) and request.http_status >= 400
    if http_error?, do: increment(:llm_http_errors)
    {current, active} = Map.pop(state.active, request.request_id)
    if current, do: Process.demonitor(current.monitor, [:flush])

    outcome =
      cond do
        phase == :exception -> :exception
        http_error? -> :http_error
        true -> :finished
      end

    request =
      request
      |> Map.put(:pid, if(current, do: current.pid, else: request.pid))
      |> Map.put(:outcome, outcome)

    recent = Enum.reject(state.recent, &(&1.request_id == request.request_id))

    usage =
      Enum.reduce(request.usage, state.usage, fn
        {_, nil}, total -> total
        {key, value}, total -> Map.update(total, key, value, &(&1 + value))
      end)

    {:noreply,
     %{
       state
       | active: active,
         recent: Enum.take([request | recent], @limit),
         usage: usage,
         missing_cost:
           state.missing_cost +
             if(phase == :stop and is_nil(request.usage.total_cost), do: 1, else: 0)
     }}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.active, fn {_, request} -> request.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {id, request} ->
        request =
          request
          |> Map.drop([:monitor])
          |> Map.put(:elapsed_ms, System.monotonic_time(:millisecond) - request.started_ms)
          |> Map.put(:outcome, :owner_stopped)

        {:noreply,
         %{
           state
           | active: Map.delete(state.active, id),
             recent: Enum.take([request | state.recent], @limit)
         }}
    end
  end

  defp increment(key), do: :ets.update_counter(@table, key, {2, 1})
  defp duration_ms(nil), do: nil
  defp duration_ms(duration), do: System.convert_time_unit(duration, :native, :microsecond) / 1000
  defp scalar(nil), do: nil
  defp scalar(value) when is_atom(value), do: to_string(value)
  defp scalar(value) when is_binary(value) or is_number(value), do: value
  defp scalar(_), do: nil
end
