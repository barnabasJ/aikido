defmodule AgentExamples.HookedAssistant do
  @moduledoc """
  An assistant with ordered Lua gates and independent asynchronous observers.
  Callers can replace `hooks` at start, just like the model and tools.
  """
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "example_hooked_assistant"
  end

  ai do
    system_prompt "Use the supplied tools to analyze the user's text. Consider hook-supplied context when answering."
    max_iterations 8

    hooks [
      %{
        name: "briefing",
        event: :before_model,
        mode: :sync,
        lua_options: [otp_app: :agent_examples, labels: [:analysis]],
        script: """
        if event.iteration == 0 then
          local stats = assert(analysis.text_stats({input = {text = "Keep the answer concise and cite the tool results."}}))
          return {context = "Keep the answer concise and cite the tool results. The hook briefing has " .. stats.words .. " words."}
        end
        return {decision = "continue"}
        """
      },
      %{
        name: "tool_gate",
        event: :before_tool,
        mode: :sync,
        script: """
        local input = event.tool_call.arguments.input or event.tool_call.arguments
        if string.find(input.text or "", "deny-tools", 1, true) then
          return {decision = "deny", message = "The example tool gate denied this run."}
        end
        if event.tool_call.name == "stamp" then
          return {decision = "continue", context = "The stamp tool records this caller's label."}
        end
        return {decision = "continue"}
        """
      },
      %{
        name: "tool_observer",
        event: :after_tool,
        mode: :async,
        script: """
        aikido.send_context("An asynchronous observer saw " .. event.name .. " finish.")
        """
      }
    ]
  end
end
