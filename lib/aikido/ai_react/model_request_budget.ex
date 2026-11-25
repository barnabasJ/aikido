defmodule Aikido.AiReact.ModelRequestBudget do
  @moduledoc "Carries the supervising cutoff into native ReqLLM request and retry budgets."
  alias Aikido.AiReact.{AttemptBudget, AttemptTiming}

  @doc "Recheck preparation time and forward the original absolute cutoff without restarting it."
  def options(options, timing, %AttemptBudget{} = budget) do
    inherited =
      if budget.deadline_at,
        do: budget.deadline_at - AttemptTiming.system_ms(timing),
        else: :infinity

    if min(budget.monotonic_deadline - AttemptTiming.monotonic_ms(timing), inherited) > 0 do
      with {:ok, native} <-
             ReqLLM.Provider.Options.validate_generation_options(
               Keyword.take(options, [:total_deadline_at]),
               only: [:total_deadline_at]
             ) do
        absolute =
          min(
            Keyword.get(native, :total_deadline_at, budget.absolute_deadline_at),
            budget.absolute_deadline_at
          )

        {:ok, Keyword.put(options, :total_deadline_at, absolute)}
      end
    else
      {:error,
       Aikido.AiReact.Errors.ModelTimeout.exception(
         kind: if(budget.deadline_at && inherited <= 0, do: :deadline, else: :attempt),
         timeout: budget.timeout_ms
       )}
    end
  end
end
