defmodule Aikido.Bench.Context do
  @moduledoc false

  alias Aikido.AiReact.Conversation
  alias ReqLLM.Context

  def run(settings) do
    message = Context.user("One additional message with a concrete question.")

    inputs = benchmark_inputs()
    jobs = benchmark_jobs(message)
    assert_equivalent_results(inputs, jobs)
    Benchee.run(jobs, Keyword.put(settings, :inputs, inputs))
  end

  defp benchmark_inputs do
    Map.new([10, 100, 1_000], fn size ->
      messages =
        Enum.map(1..size, &Context.user("Conversation message #{&1}: some example context."))

      state = Conversation.replace_context(%{}, Context.new(messages))
      {"#{size} context messages", state}
    end)
  end

  defp benchmark_jobs(message) do
    %{
      "append + incremental token estimate" => fn state ->
        Conversation.append_message(state, message)
      end,
      "append + full token recount" => fn state ->
        context = Context.append(state.context, message)
        %{state | context: context, estimated_tokens: Conversation.estimate_tokens(context)}
      end
    }
  end

  defp assert_equivalent_results(inputs, jobs) do
    # The baseline and incremental path must agree on context and estimated tokens.
    for {_label, input} <- inputs do
      [result | rest] = Enum.map(jobs, fn {_name, job} -> job.(input) end)
      true = Enum.all?(rest, &(&1 == result))
    end
  end
end
