defmodule AgentExamples.AdaptiveAssistant.Client do
  @moduledoc "Offline model that names the prepared tools and executes the first one on each user turn."
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text(_model, messages, opts) do
    current = messages |> Enum.reverse() |> Enum.take_while(&(&1.role != :user)) |> Enum.reverse()
    names = Enum.map(opts[:tools], & &1.name)

    if Enum.any?(current, &(&1.role == :tool)) do
      AgentExamples.Scenarios.Responses.answer(
        "Prepared tools: #{Enum.join(names, ", ")}. " <>
          Enum.map_join(current, &AgentExamples.Scenarios.Responses.text/1)
      )
    else
      AgentExamples.Scenarios.Responses.call(hd(names), %{
        text: "Scoped tools from application configuration"
      })
    end
  end
end
