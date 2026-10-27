defmodule AgentExamples.ResilientAssistant.Client do
  @moduledoc "Offline retry exhaustion, timeout, tool failure and alternating-cycle scenarios."
  @behaviour Aikido.AiReact.Client
  alias AgentExamples.Scenarios.Responses
  alias Aikido.AiReact.Types.ToolCycleWarning

  @impl true
  def generate_text(_model, messages, _opts) do
    # The scripted scenario follows the latest authored query. Native cycle
    # warnings stay in the real conversation, but are not a new scenario input.
    messages = Enum.reject(messages, &cycle_warning?/1)
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

  defp cycle_warning?(%{role: :user, metadata: metadata}) when is_map(metadata) do
    payload =
      Map.get(metadata, :aikido_tool_cycle_warning) ||
        Map.get(metadata, "aikido_tool_cycle_warning")

    with payload when is_map(payload) <- payload,
         {:ok, %ToolCycleWarning{}} <- ToolCycleWarning.new(payload) do
      true
    else
      _ordinary_message -> false
    end
  end

  defp cycle_warning?(_message), do: false
end
