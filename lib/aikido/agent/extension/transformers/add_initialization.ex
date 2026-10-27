defmodule Aikido.Agent.Extension.Transformers.AddInitialization do
  @moduledoc false
  use Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    with {:ok, arguments} <- build_initialization_arguments(),
         {:ok, dsl} <- add_initialization_action(dsl, arguments) do
      Ash.Resource.Builder.add_new_interface(dsl, :initialize, action: :initialize)
    end
  end

  defp build_initialization_arguments do
    with {:ok, id} <-
           Ash.Resource.Builder.build_action_argument(:id, :string,
             allow_nil?: false,
             default: &Ash.UUIDv7.generate/0
           ),
         {:ok, state} <-
           Ash.Resource.Builder.build_action_argument(:state, :map,
             allow_nil?: false,
             default: %{}
           ) do
      {:ok, [id, state]}
    end
  end

  defp add_initialization_action(dsl, arguments) do
    Ash.Resource.Builder.add_new_action(dsl, :action, :initialize,
      returns: Aikido.Agent,
      public?: false,
      arguments: arguments,
      run:
        {Aikido.Agent.Actions.Initialize,
         path: Spark.Dsl.Extension.get_opt(dsl, [:agent], :path),
         slices: Spark.Dsl.Transformer.get_persisted(dsl, :slice_instances, [])}
    )
  end
end
