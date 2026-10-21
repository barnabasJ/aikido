defmodule Aikido.AiReact.ModelStream do
  @moduledoc """
  Batches model text and thinking deltas while consuming a native ReqLLM stream.

  ReqLLM assembles tool calls and response metadata. The supplied callbacks
  receive deltas, progress and cleanup work; this adapter never writes state.
  """
  def call(client, model, messages, opts, emit, notify, batch_bytes, batch_ms) do
    with {:ok, response} <- client.stream_text(model, messages, opts) do
      notify.({:cleanup, fn -> ReqLLM.StreamResponse.close(response) end})

      stream =
        Stream.transform(
          response.stream,
          fn -> {"", "", System.monotonic_time(:millisecond)} end,
          fn chunk, {text, thinking, last_emit} ->
            if chunk.type in [:content, :thinking, :tool_call], do: notify.(:progress)
            text = if chunk.type == :content, do: text <> (chunk.text || ""), else: text

            thinking =
              if chunk.type == :thinking, do: thinking <> (chunk.text || ""), else: thinking

            pending =
              if byte_size(text) + byte_size(thinking) >= batch_bytes ||
                   System.monotonic_time(:millisecond) - last_emit >= batch_ms do
                emit.(text, thinking)
                {"", "", System.monotonic_time(:millisecond)}
              else
                {text, thinking, last_emit}
              end

            {[chunk], pending}
          end,
          fn {text, thinking, _last_emit} = pending ->
            if text != "" || thinking != "", do: emit.(text, thinking)
            {[], pending}
          end,
          fn _ -> :ok end
        )

      ReqLLM.StreamResponse.to_response(%{response | stream: stream})
    end
  end
end
