defmodule AgentExamples.AI.StreamingClient do
  @moduledoc "Offline streaming using native ReqLLM chunks and responses; no provider key is needed."

  defdelegate generate_text(model, messages, opts), to: AgentExamples.AI.ScriptedClient

  def stream_text(_model, messages, _opts) do
    user_messages = Enum.filter(messages, &(&1.role == :user))
    latest = user_messages |> List.last() |> Map.fetch!(:content) |> Enum.map_join(& &1.text)
    text = "I remember #{length(user_messages)} user messages. Latest: #{latest}"

    chunks =
      [ReqLLM.StreamChunk.thinking("Reviewing conversation history. ")] ++
        Enum.map(String.graphemes(text), &ReqLLM.StreamChunk.text/1)

    stream =
      Stream.map(chunks, fn chunk ->
        # A paced local stream makes incremental rendering visible in the demo.
        receive do
        after
          10 -> chunk
        end
      end)

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
