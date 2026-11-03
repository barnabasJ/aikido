defmodule Aikido.Thread.Followers do
  @moduledoc "Pure one-batch demand, exact acknowledgement and coalesced journal availability."
  alias Aikido.Thread.{Journal, Types}

  @doc "Authorize at the owning action, then register and offer one replay batch atomically."
  def follow(thread, arguments, context, channel) do
    cursor =
      arguments.after ||
        Types.Cursor.new!(generation: thread.generation, sequence: thread.first_sequence - 1)

    existing = Enum.find(thread.followers, &(&1.consumer == arguments.consumer))

    follower =
      if existing && existing.cursor == cursor && existing.batch_size == arguments.batch_size &&
           !existing.paused?,
         do: existing,
         else:
           Types.Follower.new!(
             consumer: arguments.consumer,
             cursor: cursor,
             batch_size: arguments.batch_size
           )

    {follower, directives} = demand(thread, follower, context, channel)
    {replace(thread, follower), directives}
  end

  @doc "Accept only the exact SQL-committed range, then advertise without pushing more payload."
  def acknowledge(thread, arguments, context, channel) do
    followers =
      Enum.map(thread.followers, fn follower ->
        case follower.in_flight do
          %{id: id, generation: generation, last_sequence: sequence}
          when follower.consumer == arguments.consumer and id == arguments.batch_id and
                 generation == arguments.cursor.generation and
                 sequence == arguments.cursor.sequence ->
            %{follower | cursor: arguments.cursor, in_flight: nil, notice_id: nil}

          _ ->
            follower
        end
      end)

    offer_all(%{thread | followers: followers}, context, channel)
  end

  @doc "Remove a consumer registration without touching retained journal entries."
  def unfollow(thread, consumer),
    do: %{thread | followers: Enum.reject(thread.followers, &(&1.consumer == consumer))}

  @doc "Coalesce availability hints; Append never grants fresh private-data demand."
  def offer_all(thread, context, channel) do
    {followers, directives} =
      Enum.map_reduce(thread.followers, [], fn follower, effects ->
        {follower, planned} = advertise(thread, follower, context, channel, false)
        {follower, effects ++ planned}
      end)

    {%{thread | followers: followers}, directives}
  end

  @doc "Retry only a current availability notice, never a private batch under stale read authority."
  def retry(thread, arguments, context, channel) do
    case Enum.find(thread.followers, &(&1.consumer == arguments.consumer)) do
      %{notice_id: notice, paused?: false} = follower
      when notice == arguments.notice_id and thread.generation == arguments.generation ->
        {thread, availability(thread, follower, context, channel, true)}

      _ ->
        {thread, []}
    end
  end

  @doc "Restore availability for saved registrations; a fresh authorized Follow is needed for data."
  def resume(thread, context, channel) do
    {followers, directives} =
      Enum.map_reduce(thread.followers, [], fn follower, effects ->
        {follower, planned} = advertise(thread, follower, context, channel, true)
        {follower, effects ++ planned}
      end)

    {%{thread | followers: followers}, directives}
  end

  defp demand(thread, follower, context, channel) do
    case gap(thread, follower.cursor) do
      nil -> demand_range(thread, follower, context, channel)
      reason -> report_gap(thread, follower, context, channel, reason)
    end
  end

  defp demand_range(thread, %{in_flight: batch} = follower, context, channel)
       when not is_nil(batch),
       do: {follower, batch_delivery(thread, follower, context, channel)}

  defp demand_range(thread, follower, context, channel) do
    entries =
      thread.entries
      |> Enum.drop_while(&(&1.seq <= follower.cursor.sequence))
      |> Enum.take(follower.batch_size)

    case entries do
      [] ->
        {follower, availability(thread, follower, context, channel, false)}

      [first | _] ->
        batch =
          Types.Batch.new!(
            id: context.signal.id,
            generation: thread.generation,
            first_sequence: first.seq,
            last_sequence: List.last(entries).seq
          )

        follower = %{follower | in_flight: batch, notice_id: batch.id}
        {follower, batch_delivery(thread, follower, context, channel)}
    end
  end

  defp advertise(_thread, %{paused?: true} = follower, _context, _channel, _force),
    do: {follower, []}

  defp advertise(thread, follower, context, channel, force) do
    case gap(thread, follower.cursor) do
      nil ->
        if pending?(thread, follower) && (force || is_nil(follower.notice_id)) do
          follower = %{follower | notice_id: follower.notice_id || context.signal.id}
          {follower, availability(thread, follower, context, channel, true)}
        else
          {follower, []}
        end

      reason ->
        report_gap(thread, follower, context, channel, reason)
    end
  end

  defp report_gap(thread, follower, context, channel, reason) do
    available =
      Types.Cursor.new!(generation: thread.generation, sequence: thread.first_sequence - 1)

    signal = %Aikido.Signal{
      type: "aikido.thread.gap",
      data:
        Map.merge(envelope(follower, context, channel), %{
          request_id: context.signal.id,
          requested: follower.cursor,
          available: available,
          reason: reason
        })
    }

    {%{follower | paused?: true, in_flight: nil, notice_id: nil},
     [delivery(follower.consumer, signal)]}
  end

  defp gap(thread, cursor) do
    cond do
      cursor.generation != thread.generation -> :generation_changed
      cursor.sequence < thread.first_sequence - 1 -> :pruned
      cursor.sequence >= Journal.next_sequence(thread) -> :ahead
      true -> nil
    end
  end

  defp pending?(thread, follower),
    do: follower.cursor.sequence < Journal.next_sequence(thread) - 1

  defp batch_delivery(thread, follower, context, channel) do
    batch = follower.in_flight

    entries =
      Enum.filter(
        thread.entries,
        &(&1.seq >= batch.first_sequence && &1.seq <= batch.last_sequence)
      )

    signal = %Aikido.Signal{
      type: "aikido.thread.batch",
      data:
        Map.merge(envelope(follower, context, channel), %{
          request_id: context.signal.id,
          batch: batch,
          entries: entries,
          metadata: thread.metadata
        })
    }

    [retry_timer(thread, follower, context, channel), delivery(follower.consumer, signal)]
  end

  defp availability(thread, follower, context, channel, retry?) do
    signal = %Aikido.Signal{
      type: "aikido.thread.available",
      data:
        Map.merge(envelope(follower, context, channel), %{
          request_id: context.signal.id,
          cursor:
            Types.Cursor.new!(
              generation: thread.generation,
              sequence: Journal.next_sequence(thread) - 1
            ),
          pending?: pending?(thread, follower),
          batch: follower.in_flight
        })
    }

    timer = if retry?, do: [retry_timer(thread, follower, context, channel)], else: []
    timer ++ [delivery(follower.consumer, signal)]
  end

  defp retry_timer(thread, follower, context, channel) do
    type = if channel == :thread, do: "aikido.thread.retry", else: "aikido.ash.team.retry_roster"

    signal = %Aikido.Signal{
      type: type,
      scope: context[:execution_scope] || %{},
      data: %{
        consumer: follower.consumer,
        path: context.slice_path,
        notice_id: follower.notice_id,
        generation: thread.generation
      }
    }

    Aikido.Directives.schedule(thread.retry_ms, signal)
  end

  defp replace(thread, follower) do
    followers = Enum.reject(thread.followers, &(&1.consumer == follower.consumer))
    %{thread | followers: followers ++ [follower]}
  end

  defp envelope(follower, context, channel),
    do: %{
      source: source(context),
      consumer: follower.consumer,
      path: context.slice_path,
      channel: channel
    }

  defp delivery(consumer, signal),
    do: Aikido.Thread.Directives.Deliver.new!(target: consumer, signal: signal, kind: :batch)

  defp source(context),
    do:
      Aikido.Agent.Reference.new!(
        id: context.agent_id,
        resource: context.agent_module,
        aikido: context.aikido,
        partition: context.partition
      )
end
