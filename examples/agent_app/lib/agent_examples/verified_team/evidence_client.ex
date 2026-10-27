defmodule AgentExamples.VerifiedTeam.EvidenceClient do
  @moduledoc "Offline evidence check with bounded simulated provider latency."
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text("offline", _messages, _opts) do
    receive do
    after
      800 -> AgentExamples.Scenarios.Responses.answer("Evidence checked: a background result returns through a correlated team signal.")
    end
  end

  def generate_text(model, messages, opts),
    do: AgentExamples.AI.LiveClient.generate_text(model, messages, opts)
end
