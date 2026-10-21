defmodule Aikido.Agent.Extension.Verifiers.UniquePaths do
  @moduledoc """
  Asserts that the agent's own slice path and every slice path are
  unique. Raises a `Spark.Error.DslError` listing the duplicated paths
  at compile time.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    own_path = Verifier.get_option(dsl_state, [:agent], :path)
    slice_paths = Verifier.get_persisted(dsl_state, :slice_paths) || []

    duplicates = if own_path in slice_paths, do: [own_path], else: []

    if duplicates == [] do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         message: "Duplicate slice paths: #{inspect(Enum.uniq(duplicates))}",
         path: [:agent]
       )}
    end
  end
end
