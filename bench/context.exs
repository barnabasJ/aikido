defmodule Aikido.Bench.Context do
  @moduledoc false

  alias Aikido.AI.Context, as: Conversation
  alias ReqLLM.Context

  def run(settings) do
    message = Context.user("One additional message with a concrete question.")

    inputs =
      Map.new([10, 100, 1_000], fn size ->
        messages =
          Enum.map(1..size, &Context.user("Conversation message #{&1}: some example context."))

        state = Conversation.replace_context(%{}, Context.new(messages))
        {"#{size} context messages", state}
      end)

    jobs = %{
      "append + incremental token estimate" => fn state ->
        Conversation.append_message(state, message)
      end,
      "append + full token recount" => fn state ->
        context = Context.append(state.context, message)
        %{state | context: context, estimated_tokens: Conversation.estimate_tokens(context)}
      end
    }

    # The baseline and incremental path must agree on context and estimated tokens.
    for {_label, input} <- inputs do
      [result | rest] = Enum.map(jobs, fn {_name, job} -> job.(input) end)
      true = Enum.all?(rest, &(&1 == result))
    end

    Benchee.run(jobs, Keyword.put(settings, :inputs, inputs))
  end
end
