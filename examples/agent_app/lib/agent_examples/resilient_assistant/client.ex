defmodule AgentExamples.ResilientAssistant.Client do
  @moduledoc "Offline retry exhaustion, timeout, tool failure and alternating-cycle scenarios."
  @behaviour Aikido.AiReact.Client
  alias AgentExamples.Scenarios.Responses

  @impl true
  def generate_text(_model, messages, _opts) do
    query = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Responses.text()

    results =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1.role != :user))
      |> Enum.count(&(&1.role == :tool))

    cond do
      query == "wait" ->
        receive do
        after
          30_000 -> Responses.answer("Wait finished")
        end

      query == "retry" ->
        {:error, :timeout}

      query == "cycle" ->
        Responses.call(if(rem(results, 2) == 0, do: "text_stats", else: "stamp"), %{
          text: "same input"
        })

      query == "errors" ->
        Responses.call("fail_example", %{})

      true ->
        Responses.answer("Recovery completed")
    end
  end
end
