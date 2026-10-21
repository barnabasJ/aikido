defmodule AgentExamples.InteractiveAssistant do
  @moduledoc """
  Experimental request/response inside Lua. Only Lua interprets the response
  as permission to run a tool. The application supplies the request callback
  at startup; Aikido does not manage UI communication.
  """
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "example_interactive_assistant"
  end

  ai do
    system_prompt "Use the supplied tools to analyze the user's text."
    max_iterations 8

    hooks [
      %{
        name: "review_stamp",
        event: :before_tool,
        mode: :sync,
        script: """
        if event.tool_call.name ~= "stamp" then
          return {decision = "continue"}
        end

        local answer, err = aikido.request("tool.review", {
          title = "Allow the stamp tool to run?",
          details = event.tool_call,
          choices = {"approve", "deny"}
        })

        if err then
          return {decision = "deny", message = "Request ended: " .. err.message}
        end
        if answer.choice == "approve" then
          return {decision = "continue", context = "Lua received the response: " .. answer.choice}
        end
        return {decision = "deny", message = "Lua chose to stop after the response."}
        """
      }
    ]
  end
end
