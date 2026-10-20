defmodule Aikido.Ash.Verifiers.Domain do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    entries = Verifier.get_entities(dsl, [:agents])

    cond do
      Enum.any?(entries, &(Aikido.Ash.Agent not in Spark.extensions(&1.resource))) ->
        error("Domain agents must use the Aikido.Ash.Agent extension")

      true ->
        :ok
    end
  end

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:agents])}
end
