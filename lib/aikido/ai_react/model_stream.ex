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
            {"", "", AttemptTiming.monotonic_ms(timing),
             %{wire_chunks: 0, qualifying_chunks: 0, nonqualifying_chunks: 0, rendered_chunks: 0}}
          end,
          fn chunk, {text, thinking, last_emit, counts} ->
            counts = count_chunk(counts, chunk)

            observation =
              if counts.wire_chunks == 1,
                do: Map.put(counts, :first_chunk_at, AttemptTiming.system_ms(timing)),
                else: counts

            notify.({:wire, observation, generation_progress?(chunk)})
            text = if chunk.type == :content, do: text <> (chunk.text || ""), else: text

            thinking =
              if chunk.type == :thinking, do: thinking <> (chunk.text || ""), else: thinking

            pending =
              if byte_size(text) + byte_size(thinking) >= batch_bytes ||
                   AttemptTiming.monotonic_ms(timing) - last_emit >= batch_ms do
                emit.(text, thinking)
                {"", "", AttemptTiming.monotonic_ms(timing), counts}
              else
                {text, thinking, last_emit, counts}
              end

            {[chunk], pending}
          end,
          fn {text, thinking, _last_emit, counts} = pending ->
            if text != "" || thinking != "", do: emit.(text, thinking)
            notify.({:observation, counts})
            {[], pending}
          end,
          fn _ -> :ok end
        )

      ReqLLM.StreamResponse.to_response(%{response | stream: stream})
    end
  end

  defp count_chunk(counts, chunk) do
    progress_key =
      if generation_progress?(chunk), do: :qualifying_chunks, else: :nonqualifying_chunks

    rendered? = chunk.type in [:content, :thinking] && is_binary(chunk.text) && chunk.text != ""

    counts
    |> Map.update!(:wire_chunks, &(&1 + 1))
    |> Map.update!(progress_key, &(&1 + 1))
    |> Map.update!(:rendered_chunks, &(&1 + if(rendered?, do: 1, else: 0)))
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
