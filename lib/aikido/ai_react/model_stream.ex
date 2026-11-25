defmodule Aikido.AiReact.ModelStream do
  @moduledoc """
  Batches model text and thinking deltas while consuming a native ReqLLM stream.

  ReqLLM assembles tool calls and response metadata. The supplied callbacks
  receive deltas, progress and cleanup work; this adapter never writes state.
  """
  alias Aikido.AiReact.AttemptTiming

  def call(client, model, messages, opts, emit, notify, batch_bytes, batch_ms)
      when is_integer(batch_ms),
      do: call(client, model, messages, opts, emit, notify, batch_bytes, {batch_ms, nil})

  def call(client, model, messages, opts, emit, notify, batch_bytes, {batch_ms, timing}) do
    timing = AttemptTiming.resolve(timing)

    with {:ok, response} <- client.stream_text(model, messages, opts) do
      notify.({:cleanup, fn -> ReqLLM.StreamResponse.close(response) end})

      notify.(
        {:observation,
         %{
           opened: true,
           wire_chunks: 0,
           qualifying_chunks: 0,
           nonqualifying_chunks: 0,
           rendered_chunks: 0
         }}
      )

      stream =
        Stream.transform(
          response.stream,
          fn ->
            %{
              text: "",
              thinking: "",
              sequence: 0,
              in_flight: nil,
              last_emit: AttemptTiming.monotonic_ms(timing),
              counts: %{
                wire_chunks: 0,
                qualifying_chunks: 0,
                nonqualifying_chunks: 0,
                rendered_chunks: 0
              }
            }
          end,
          fn chunk, pending ->
            counts = count_chunk(pending.counts, chunk, timing)
            progress_at = if generation_progress?(chunk), do: AttemptTiming.monotonic_ms(timing)
            notify.({:wire, counts, progress_at})
            pending = poll_receipt(%{pending | counts: counts}, emit)
            pending = append_delta(pending, chunk)
            pending = flush_at_capacity(pending, emit, batch_bytes, batch_ms, timing)
            {[chunk], pending}
          end,
          fn pending ->
            pending = await_receipt(pending, emit)

            pending =
              if buffered?(pending), do: submit_batch(pending, emit, timing), else: pending

            pending = await_receipt(pending, emit)
            notify.({:observation, pending.counts})
            {[], pending}
          end,
          fn _ -> :ok end
        )

      ReqLLM.StreamResponse.to_response(%{response | stream: stream})
    end
  end

  defp append_delta(pending, %{type: :content, text: text}),
    do: %{pending | text: pending.text <> (text || "")}

  defp append_delta(pending, %{type: :thinking, text: text}),
    do: %{pending | thinking: pending.thinking <> (text || "")}

  defp append_delta(pending, _chunk), do: pending

  defp flush_at_capacity(pending, delivery, bytes, milliseconds, timing) do
    full? = byte_size(pending.text) + byte_size(pending.thinking) >= bytes

    due? =
      is_nil(pending.in_flight) &&
        AttemptTiming.monotonic_ms(timing) - pending.last_emit >= milliseconds

    if buffered?(pending) && (full? || due?) do
      pending |> await_receipt(delivery) |> submit_batch(delivery, timing)
    else
      pending
    end
  end

  defp buffered?(pending), do: pending.text != "" || pending.thinking != ""

  defp submit_batch(pending, delivery, timing) do
    case delivery.submit.(pending.text, pending.thinking, pending.sequence + 1) do
      {:ok, request} ->
        %{
          pending
          | in_flight: request,
            sequence: pending.sequence + 1,
            text: "",
            thinking: "",
            last_emit: AttemptTiming.monotonic_ms(timing)
        }

      {:error, error} ->
        raise error
    end
  end

  defp poll_receipt(%{in_flight: nil} = pending, _delivery), do: pending

  defp poll_receipt(pending, delivery) do
    case delivery.poll.(pending.in_flight) do
      :pending -> pending
      :ok -> %{pending | in_flight: nil}
      {:error, error} -> raise error
    end
  end

  defp await_receipt(%{in_flight: nil} = pending, _delivery), do: pending

  defp await_receipt(pending, delivery) do
    case delivery.await.(pending.in_flight) do
      :ok -> %{pending | in_flight: nil}
      {:error, error} -> raise error
    end
  end

  defp count_chunk(counts, chunk, timing) do
    progress_key =
      if generation_progress?(chunk), do: :qualifying_chunks, else: :nonqualifying_chunks

    rendered? = chunk.type in [:content, :thinking] && is_binary(chunk.text) && chunk.text != ""

    updated =
      counts
      |> Map.update!(:wire_chunks, &(&1 + 1))
      |> Map.update!(progress_key, &(&1 + 1))
      |> Map.update!(:rendered_chunks, &(&1 + if(rendered?, do: 1, else: 0)))

    updated =
      if counts.wire_chunks == 0,
        do: Map.put(updated, :first_chunk_at, AttemptTiming.system_ms(timing)),
        else: updated

    if counts.qualifying_chunks == 0 && generation_progress?(chunk),
      do: Map.put(updated, :first_progress_at, AttemptTiming.system_ms(timing)),
      else: updated
  end

  @doc "Whether a parsed chunk contains generation content rather than an empty heartbeat."
  def generation_progress?(%{type: type, text: text}) when type in [:content, :thinking],
    do: is_binary(text) && text != ""

  def generation_progress?(%{type: :tool_call} = chunk),
    do: nonempty?(chunk.name) || nonempty?(chunk.arguments)

  def generation_progress?(%{type: :content_part, content_part: part}), do: nonempty?(part)
  def generation_progress?(_chunk), do: false

  defp nonempty?(value) when is_binary(value), do: value != ""
  defp nonempty?(value) when is_map(value), do: map_size(value) > 0
  defp nonempty?(value) when is_list(value), do: value != []
  defp nonempty?(_value), do: false
end
