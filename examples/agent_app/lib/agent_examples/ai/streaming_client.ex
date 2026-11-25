defmodule AgentExamples.AI.StreamingClient do
  @moduledoc "Offline streaming using native ReqLLM chunks and responses; no provider key is needed."

  defdelegate generate_text(model, messages, opts), to: AgentExamples.AI.ScriptedClient

  def stream_text(_model, messages, _opts) do
    user_messages = Enum.filter(messages, &(&1.role == :user))
    latest = user_messages |> List.last() |> Map.fetch!(:content) |> Enum.map_join(& &1.text)
    burst? = latest == "burst"

    text =
      if burst? do
        "## Buffered stream\n\n" <>
          String.duplicate(
            "The producer keeps one batch in flight and buffers one more while it waits.\n\n",
            16
          )
      else
        "I remember #{length(user_messages)} user messages. Latest: #{latest}"
      end

    chunks =
      [ReqLLM.StreamChunk.thinking("Reviewing conversation history. ")] ++
        Enum.map(String.graphemes(text), &ReqLLM.StreamChunk.text/1)

    stream =
      if burst? do
        Stream.map(chunks, & &1)
      else
        Stream.map(chunks, fn chunk ->
          receive do
          after
            10 -> chunk
          end
        end)
      end

    {:ok, metadata} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{
          usage: %{input_tokens: length(messages) * 10, output_tokens: String.length(text)},
          finish_reason: :stop
        }
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: stream,
       metadata_handle: metadata,
       cancel: fn -> :ok end,
       model: %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"},
       context: ReqLLM.Context.new(messages)
     }}
  end
end
