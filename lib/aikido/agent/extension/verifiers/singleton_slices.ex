defmodule Aikido.Agent.Extension.Verifiers.SingletonSlices do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    duplicate =
      dsl
      |> Spark.Dsl.Verifier.get_persisted(:slice_instances, [])
      |> Enum.group_by(& &1.module)
      |> Enum.find(fn {module, mounts} ->
        length(mounts) > 1 && Spark.Dsl.Extension.get_opt(module, [:slice], :singleton?, false)
      end)

    case duplicate do
      nil ->
        :ok

      {module, _mounts} ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:agent],
           message:
             "Slice #{inspect(module)} is singleton and may be mounted only once per agent."
         )}
    end
  end
end
