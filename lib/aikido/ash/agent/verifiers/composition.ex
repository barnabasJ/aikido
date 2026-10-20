defmodule Aikido.Ash.Agent.Verifiers.Composition do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    dsl
    |> Spark.Dsl.Verifier.get_persisted(:middleware_list, [])
    |> Enum.reduce_while(:ok, fn {module, _opts}, :ok ->
      if Code.ensure_loaded?(module) && Spark.implements_behaviour?(module, Aikido.Middleware) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Spark.Error.DslError.exception(
            message: "Middleware module #{inspect(module)} must implement Aikido.Middleware",
            path: [:agent, :middleware]
          )}}
      end
    end)
  end
end
