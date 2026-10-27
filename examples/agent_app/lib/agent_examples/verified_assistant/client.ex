defmodule AgentExamples.VerifiedAssistant.Client do
  @moduledoc "First proposes an unverified answer, then follows the continuation with an actual evidence tool."
  @behaviour Aikido.AiReact.Client
  alias AgentExamples.Scenarios.Responses

  @impl true
  def generate_text(_model, messages, _opts) do
    latest = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Responses.text()
    following = messages |> Enum.reverse() |> Enum.take_while(&(&1.role != :user))

    cond do
      Enum.any?(following, &(&1.role == :tool)) ->
        Responses.answer("Verified evidence is recorded on the delivered task.")

      String.starts_with?(latest, "Continue the remaining work") ->
        Responses.call("record_evidence", %{id: "delivered-work"})

      true ->
        Responses.answer("Provisional answer without evidence.")
    end
  end
end
