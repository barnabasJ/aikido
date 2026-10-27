defmodule Aikido.AI.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  @spec verify(dsl :: map()) :: :ok | {:error, Exception.t()}
  def verify(dsl) do
    if Aikido.Agent.Extension in Spark.extensions(dsl),
      do: validate_client(dsl),
      else:
        {:error,
         Spark.Error.DslError.exception(
           message: "AI requires Aikido.Agent.Extension",
           path: [:ai]
         )}
  end

  defp validate_client(dsl) do
    client = Spark.Dsl.Verifier.get_option(dsl, [:ai], :client, ReqLLM.Generation)

    case Ash.Type.cast_input(:module, client) do
      {:ok, module} when not is_nil(module) ->
        :ok

      _invalid ->
        {:error,
         Spark.Error.DslError.exception(
           message: "ai.client must resolve to an available module, got: #{inspect(client)}",
           path: [:ai, :client]
         )}
    end
  end
end
