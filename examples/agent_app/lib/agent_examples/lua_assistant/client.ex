defmodule AgentExamples.LuaAssistant.Client do
  @moduledoc "Offline model passing the supplied script to AshLua, or requesting docs for the current surface."
  @behaviour Aikido.AiReact.Client
  alias AgentExamples.Scenarios.Responses
  @impl true
  def generate_text(_model, messages, _opts) do
    last = List.last(messages)

    if last.role == :tool do
      Responses.answer(Responses.text(last))
    else
      text = Responses.text(last)

      if text == "docs",
        do: Responses.call("scoped_lua_docs", %{}),
        else: Responses.call("scoped_lua", %{script: text})
    end
  end
end
