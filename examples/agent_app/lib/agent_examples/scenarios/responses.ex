defmodule AgentExamples.Scenarios.Responses do
  @moduledoc "Native ReqLLM responses shared by the offline scenario clients."

  def answer(text) do
    {:ok,
     %ReqLLM.Response{
       id: "offline",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(text),
       finish_reason: :stop
     }}
  end

  def call(name, arguments) do
    {:ok,
     %ReqLLM.Response{
       id: "offline",
       model: "offline",
       context: ReqLLM.Context.new(),
       message:
         ReqLLM.Context.assistant("",
           tool_calls: [
             ReqLLM.ToolCall.new(Ash.UUIDv7.generate(), name, Jason.encode!(%{input: arguments}))
           ]
         ),
       finish_reason: :tool_calls
     }}
  end

  def text(message), do: Enum.map_join(message.content, &(&1.text || ""))
end
