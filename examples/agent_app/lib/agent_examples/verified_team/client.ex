defmodule AgentExamples.VerifiedTeam.Client do
  @moduledoc "Offline lead using ordinary tool results, required Todos and background evidence."
  @behaviour Aikido.AiReact.Client
  alias AgentExamples.Scenarios.Responses

  @impl true
  def generate_text(model, messages, opts) do
    if Enum.any?(
         messages,
         &(&1.role == :system && Responses.text(&1) =~ "Perform the requested evidence check")
       ) do
      AgentExamples.VerifiedTeam.EvidenceClient.generate_text(model, messages, opts)
    else
      messages |> current_request_messages() |> plan_evidence_work()
    end
  end

  defp current_request_messages(messages) do
    {_message, index} =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {message, _} ->
        message.role == :user && !String.starts_with?(Responses.text(message), "Task ")
      end)
      |> List.last() || {nil, 0}

    Enum.drop(messages, index)
  end

  defp plan_evidence_work(messages) do
    results =
      for message <- messages, message.role == :tool, do: Jason.decode!(Responses.text(message))

    task_id = Enum.find_value(results, & &1["task_id"])

    cond do
      Enum.any?(results, &Map.has_key?(&1, "evidence")) ->
        Responses.answer(
          "The worker's evidence was checked against the tracked assignment and recorded on the required todo."
        )

      task_id && Enum.any?(messages, &(Responses.text(&1) =~ "Evidence checked:")) ->
        Responses.call("complete_team_evidence", %{task_id: task_id})

      task_id ->
        Responses.answer("The required evidence check is still running.")

      true ->
        Responses.call("request_team_evidence", %{})
    end
  end
end
