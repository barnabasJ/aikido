defmodule Aikido.AI.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Aikido.Agent.Extension in Spark.extensions(dsl),
      do: :ok,
      else:
        {:error,
         Spark.Error.DslError.exception(
           message: "AI requires Aikido.Agent.Extension",
           path: [:ai]
         )}
  end
end
