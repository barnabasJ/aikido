defmodule Aikido.Thread.Consumer.Demand do
  @moduledoc "Owns one global replay/SQL credit window and durable per-source checkpoints."
  alias Aikido.Thread.Consumer.{Membership, Types.Credit}

  def ready(state, context) do
    sources =
      Enum.map(state.sources, fn source ->
        if source.status in [:gap, :rejected, :failed],
          do: source,
          else: %{source | status: :ready}
      end)

    %{state | sources: sources, credits: []}
    |> Membership.bootstrap_roots(context)
    |> fill(context)
  end

  def watch(state, arguments, context) do
    state = Membership.add(state, arguments.source, arguments.path, arguments.channel)

    state =
      update_source(state, arguments, fn source ->
        cursor =
          if arguments.reset? || arguments[:after], do: arguments[:after], else: source.cursor

        %{source | cursor: cursor, status: :ready, error: nil}
      end)

    fill(state, context)
  end

  def available(state, data, context) do
    source = find_source(state, data)

    if source do
      request =
        Enum.find(
          state.credits,
          &(same?(&1, data) && &1.phase == :requesting && &1.id == data.request_id)
        )

      checkpoint_covers? =
        source.cursor && data.batch &&
          source.cursor.generation == data.batch.generation &&
          source.cursor.sequence >= data.batch.last_sequence

      {state, acknowledgements} =
        if checkpoint_covers?, do: {state, [ack(data)]}, else: {state, []}

      state =
        update_source(state, data, fn source ->
          cursor =
            if request && is_nil(source.cursor) && !data.pending?,
              do: data.cursor,
              else: source.cursor

          pending? = data.pending? && behind?(source.cursor, data.cursor)

          %{
            source
            | head: data.cursor,
              cursor: cursor,
              status:
                if(source.status in [:gap, :failed, :rejected],
                  do: source.status,
                  else: if(pending?, do: :ready, else: :watching)
                )
          }
        end)

      state =
        if request && (!data.pending? || !behind?(source.cursor, data.cursor)),
          do: remove_requests(state, data),
          else: state

      {state, directives} = fill(state, context)
      {state, acknowledgements ++ directives}
    else
      {state, []}
    end
  end

  def accept_batch(state, data, context) do
    credit =
      Enum.find(
        state.credits,
        &(same?(&1, data) && &1.phase == :requesting && &1.id == data.request_id)
      )

    source = find_source(state, data)

    cond do
      is_nil(credit) || is_nil(source) ->
        {state, []}

      !valid_range?(source, data, state.batch_size) ->
        fail_request(
          state,
          data,
          :failed,
          "Source offered an invalid or oversized replay range.",
          context
        )

      true ->
        with {:ok, state} <- discover(state, data, context) do
          state =
            update_source(state, data, fn source ->
              if source.cursor,
                do: source,
                else: %{
                  source
                  | cursor:
                      Aikido.Thread.Types.Cursor.new!(
                        generation: data.batch.generation,
                        sequence: data.batch.first_sequence - 1
                      )
                }
            end)

          credits =
            Enum.map(
              state.credits,
              &if(&1 == credit, do: %{credit | phase: :writing, batch: data.batch}, else: &1)
            )

          work = %Aikido.Signal{
            type: "aikido.thread.consumer.work",
            data: Map.take(data, [:source, :path, :channel, :batch, :entries])
          }

          {%{state | credits: credits}, [Aikido.Directives.emit(work)]}
        else
          {:error, _reason} ->
            fail_request(
              state,
              data,
              :failed,
              "Source membership entry does not satisfy the native roster contract.",
              context
            )
        end
    end
  end

  def committed(state, data, context) do
    case Enum.find(
           state.credits,
           &(same?(&1, data) && &1.phase == :writing && &1.batch == data.batch)
         ) do
      nil ->
        {state, []}

      credit ->
        cursor =
          Aikido.Thread.Types.Cursor.new!(
            generation: data.batch.generation,
            sequence: data.batch.last_sequence
          )

        state =
          update_source(state, data, fn source ->
            status =
              if source.status == :gap,
                do: :gap,
                else: if(source.head && behind?(cursor, source.head), do: :ready, else: :watching)

            %{source | cursor: cursor, status: status, error: nil}
          end)

        state = %{state | credits: List.delete(state.credits, credit)}
        {state, directives} = fill(state, context)
        {state, [ack(data) | directives]}
    end
  end

  def gap(state, data, context) do
    source = find_source(state, data)

    covered? =
      source && source.cursor && source.cursor.generation == data.available.generation &&
        source.cursor.sequence >= data.available.sequence && data.reason != :ahead

    if covered? do
      state = update_source(state, data, &%{&1 | status: :ready})
      state |> remove_requests(data) |> fill(context)
    else
      fail_request(
        state,
        data,
        :gap,
        "Replay gap: #{data.reason}. Explicitly choose a recoverable SQL cursor or reset to retained beginning.",
        context
      )
    end
  end

  def rejected(state, data, context) do
    if Enum.any?(
         state.credits,
         &(same?(&1, data) && &1.id == data.request_id && &1.phase == :requesting)
       ),
       do: fail_request(state, data, :rejected, data.message, context),
       else: {state, []}
  end

  def unavailable(state, data, context) do
    keys = Enum.filter(state.sources, &same?(&1, data))

    Enum.reduce(keys, {state, []}, fn source, {current, effects} ->
      {current, planned} =
        fail_request(
          current,
          source,
          :unavailable,
          "Source has no running incarnation; no replay was accepted.",
          context
        )

      {current, effects ++ planned}
    end)
  end

  def failed(state, data, context) do
    if Enum.any?(
         state.credits,
         &(same?(&1, data) && &1.phase == :writing && &1.batch == data.batch)
       ) do
      state = %{state | credits: Enum.reject(state.credits, &same?(&1, data))}
      fail_request(state, data, :failed, data.message, context)
    else
      {state, []}
    end
  end

  def retry(state, data, context) do
    state = update_source(state, data, &%{&1 | status: :ready, error: nil})
    fill(state, context)
  end

  def request_timeout(state, arguments, context) do
    case Enum.find(
           state.credits,
           &(&1.id == arguments.request_id && &1.phase == :requesting && same?(&1, arguments))
         ) do
      nil ->
        {state, []}

      credit ->
        state = %{state | credits: List.delete(state.credits, credit)}
        state = update_source(state, credit, &%{&1 | status: :ready})
        fill(state, context)
    end
  end

  def fill(state, context) do
    capacity = state.window - length(state.credits)

    sources =
      state.sources
      |> Enum.filter(fn source ->
        source.status == :ready &&
          !Enum.any?(state.credits, fn credit -> same?(credit, source) end)
      end)
      |> Enum.take(capacity)

    Enum.reduce(sources, {state, []}, fn source, {current, effects} ->
      id = "#{context.signal.id}/#{source.source.id}/#{source.channel}/#{source.path}"

      credit =
        Credit.new!(id: id, source: source.source, path: source.path, channel: source.channel)

      follow =
        Aikido.Thread.Directives.Follow.new!(
          source: source.source,
          path: source.path,
          channel: source.channel,
          after: source.cursor,
          batch_size: current.batch_size,
          request_id: id
        )

      timeout = %Aikido.Signal{
        type: "aikido.thread.consumer.request_timeout",
        data: %{request_id: id, source: source.source, path: source.path, channel: source.channel}
      }

      current = %{current | credits: current.credits ++ [credit]}

      {current,
       effects ++ [Aikido.Directives.schedule(current.request_timeout_ms, timeout), follow]}
    end)
  end

  def changes(previous, updated) do
    updated
    |> Map.take(Enum.map(Ash.Resource.Info.attributes(Aikido.Thread.Consumer.Slice), & &1.name))
    |> Map.reject(fn {key, value} -> Map.get(previous, key) == value end)
  end

  defp fail_request(state, data, status, message, context) do
    state = update_source(state, data, &%{&1 | status: status, error: message})
    state = remove_requests(state, data)
    fill(state, context)
  end

  defp discover(state, %{channel: :roster, entries: entries}, context),
    do: Membership.apply_entries(state, entries, context)

  defp discover(state, _data, _context), do: {:ok, state}
  defp behind?(nil, _head), do: true

  defp behind?(cursor, head),
    do: cursor.generation != head.generation || cursor.sequence < head.sequence

  defp find_source(state, key), do: Enum.find(state.sources, &same?(&1, key))

  defp same?(left, right),
    do: left.source == right.source && left.path == right.path && left.channel == right.channel

  defp update_source(state, key, change) do
    case find_source(state, key) do
      nil -> state
      source -> %{state | sources: List.delete(state.sources, source) ++ [change.(source)]}
    end
  end

  defp remove_requests(state, key),
    do: %{
      state
      | credits: Enum.reject(state.credits, &(same?(&1, key) && &1.phase == :requesting))
    }

  defp ack(data),
    do:
      Aikido.Thread.Directives.Ack.new!(
        source: data.source,
        path: data.path,
        channel: data.channel,
        batch: data.batch
      )

  defp valid_range?(source, data, limit) do
    batch = data.batch
    cursor = source.cursor
    expected = if cursor, do: cursor.sequence + 1, else: batch.first_sequence

    length(data.entries) <= limit && batch.first_sequence <= batch.last_sequence &&
      batch.first_sequence == expected && (!cursor || cursor.generation == batch.generation) &&
      Enum.map(data.entries, & &1.seq) == Enum.to_list(batch.first_sequence..batch.last_sequence)
  end
end
